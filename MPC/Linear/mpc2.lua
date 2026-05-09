-- ================================================================
--  mpc2.lua  --  Linear Model Predictive Controller
--  ----------------------------------------------------------------
--  A reusable receding-horizon MPC for SISO 2-state systems.
--  Used by 9flatgraph for pitch and roll axes.
--
--  REQUIRES: CC: Advanced Math
--    https://github.com/TechTastic/Advanced-Math
--    Provides the `matrix` global (auto-loaded from rom/apis/).
--
-- ================================================================
--  CC: ADVANCED MATH API CHEAT-SHEET (the trap that ate the old code)
--  ----------------------------------------------------------------
--  The matrix module exposes ONLY these functions on the module table:
--      matrix.new(rows, cols, fill)         <-- DOT
--      matrix.from2DArray(t)                <-- DOT
--      matrix.fromVector(v, isRow)          <-- DOT
--      matrix.fromQuaternion(q)             <-- DOT
--      matrix.identity(rows, cols)          <-- DOT (BUGGY: returns all-1s)
--      matrix.solve(A, b, tol)              <-- DOT
--
--  Everything else (mul, add, sub, transpose, inverse, ...) lives on
--  matrix INSTANCES via the metatable.  You CANNOT write
--      matrix.mul(a, b)         -- nil value, will crash
--  You MUST write either
--      a * b                    -- via __mul metamethod
--      a:mul(b)                 -- via metatable __index
--  Same for add (`a + b` or `a:add(b)`), sub, div, unm, pow.
--
--  Transpose, inverse, determinant, clone etc. are unary methods:
--      m:transpose()
--      m:inverse()
--
--  GOTCHA #2: matrix.new(r, c) with NO third arg fills with 1, not 0.
--  Always pass an explicit 0 (or a function) when you want zeros.
--
--  GOTCHA #3: matrix.identity is broken in this library -- it just
--  calls new(r, c) which fills with 1s, not an identity matrix.
--  Use matrix.new(n, n, function(r,c) return r==c and 1 or 0 end).
-- ================================================================
--
--  THEORY (unchanged)
--  ----------------------------------------------------------------
--  Each tick the controller solves a quadratic program:
--
--      min  J(U) = sum_{k=1..N} [ Q*(x_k - r_k)^2 + R*u_k^2 ]
--                + sum_{k=1..N} [ S*(u_k - u_{k-1})^2 ]
--    s.t. x_{k+1} = A * x_k + B * u_k + d_k
--
--  Stacking N predictions:  X = Phi * U + Psi * x0 + D_stack
--  Minimizing analytically over U yields  H * U = g  with:
--    H = Phi' * Q_big * Phi + R_big + D'*S*D
--    g = Phi' * Q_big * (rseq - Psi*x0 - D_stack) - S_lin
--
--  matrix.solve(H, g) gives U*, take U*[1] as the control to apply.
-- ================================================================

local mpc = {}

-- ================================================================
-- MATRIX API LOAD
-- ================================================================
-- Per the library author: "it's not a require'd module -- if it's
-- there, it's the `matrix` global; if it's not, you don't have it."
-- ComputerCraft auto-loads ROM apis at startup, so by the time this
-- file is required, _G.matrix should already exist.

if not _G.matrix then
    error("CC: Advanced Math is required.\n" ..
          "The 'matrix' global API was not found.\n" ..
          "Install Advanced Math: https://github.com/TechTastic/Advanced-Math")
end
local matrix = _G.matrix


-- ================================================================
-- INTERNAL HELPERS
-- ================================================================

-- Build prediction matrices Phi (2N x N), Psi (2N x 2), D_stack (2N x 1)
-- from a single (A, B, d) linearization re-used across the horizon.
local function buildPrediction(A, B, d, N)
    -- All zero-filled (third arg = 0, NOT nil -- nil fills with 1).
    local Phi = matrix.new(2*N, N, 0)
    local Psi = matrix.new(2*N, 2, 0)
    local Dst = matrix.new(2*N, 1, 0)

    -- Aacc starts as I_2 (identity).  Use the function-form of new
    -- because matrix.identity in this library is broken.
    local Aacc   = matrix.new(2, 2, function(r, c) return (r == c) and 1 or 0 end)
    local Daccum = matrix.new(2, 1, 0)
    local AkD    = d                          -- A^0 * d = d

    for i = 1, N do
        -- Aacc currently holds A^(i-1); advance it via __mul operator
        Aacc = A * Aacc                       -- now A^i
        -- Psi rows 2i-1, 2i = A^i
        for r = 1, 2 do
            for c = 1, 2 do
                Psi[(i-1)*2 + r][c] = Aacc[r][c]
            end
        end

        -- D_stack rows 2i-1, 2i = sum_{j=0}^{i-1} A^j * d
        Daccum = Daccum + AkD                 -- __add operator
        Dst[(i-1)*2 + 1][1] = Daccum[1][1]
        Dst[(i-1)*2 + 2][1] = Daccum[2][1]
        AkD = A * AkD                         -- advance for next iter

        -- Phi: column j contributes A^(i-j-1) * B at rows 2i-1, 2i
        local M = B                           -- A^0 * B = B at j=i-1
        for j = i-1, 0, -1 do
            Phi[(i-1)*2 + 1][j+1] = M[1][1]
            Phi[(i-1)*2 + 2][j+1] = M[2][1]
            if j > 0 then M = A * M end
        end
    end

    return Phi, Psi, Dst
end


-- ================================================================
-- PUBLIC API
-- ================================================================
-- Create a new MPC controller.
-- spec = {
--   horizon  = N,                -- prediction steps
--   dt       = 0.05,             -- timestep (matches control loop)
--   pos_w    = number,           -- state weight on position
--   vel_w    = number,           -- state weight on velocity
--   R        = number,           -- input penalty
--   S        = number,           -- input-rate penalty
--   u_min    = number,           -- input lower clamp
--   u_max    = number,           -- input upper clamp
--   slew     = number or nil,    -- max |target change|/sec  (nil = unlimited)
-- }
function mpc.new(spec)
    local self = {
        N         = spec.horizon or 8,
        dt        = spec.dt or 0.05,
        pos_w     = spec.pos_w or 10.0,
        vel_w     = spec.vel_w or 1.0,
        R         = spec.R or 0.01,
        S         = spec.S or 0.5,
        u_min     = spec.u_min or -1e9,
        u_max     = spec.u_max or  1e9,
        slew      = spec.slew,
        u_prev    = 0.0,
        target    = 0.0,
        target_set = false,
        cost_track = 0,
        cost_eff   = 0,
        cost_rate  = 0,
        traj_pos   = {},
    }

    function self:setTarget(r_user)
        if not self.target_set then
            self.target     = r_user
            self.target_set = true
        else
            if self.slew then
                local maxStep = self.slew * self.dt
                local err = r_user - self.target
                if err >  maxStep then err =  maxStep end
                if err < -maxStep then err = -maxStep end
                self.target = self.target + err
            else
                self.target = r_user
            end
        end
    end

    function self:reset()
        self.u_prev = 0
    end

    -- One MPC tick.
    --   x_now  = current state {pos, vel}    (plain 2-element Lua table)
    --   A_in   = 2x2 dynamics                (plain 2D Lua table)
    --   B_in   = 2x1 input                   (plain 2D Lua table)
    --   d_in   = 2x1 disturbance             (plain 2D Lua table)
    -- Returns u_opt (clamped scalar), and a diagnostics table.
    function self:step(x_now, A_in, B_in, d_in)
        local N = self.N

        -- Convert the plain 2D Lua tables into matrix objects.
        -- from2DArray handles nil-cells gracefully (treats them as 0).
        local A  = matrix.from2DArray(A_in)
        local B  = matrix.from2DArray(B_in)
        local d  = matrix.from2DArray(d_in)
        local x0 = matrix.from2DArray({ {x_now[1] or 0}, {x_now[2] or 0} })

        -- Build prediction stacks
        local Phi, Psi, Dst = buildPrediction(A, B, d, N)

        -- lift = Psi*x0 + Dst   (the part of X independent of U)
        local lift = (Psi * x0) + Dst

        -- Reference stack (track POSITION; velocity target = 0)
        local rseq = matrix.new(2*N, 1, 0)
        for i = 1, N do
            rseq[(i-1)*2 + 1][1] = self.target
            rseq[(i-1)*2 + 2][1] = 0
        end

        -- Q_big: diag(pos_w, vel_w) repeated N times
        local Qbig = matrix.new(2*N, 2*N, 0)
        for i = 1, N do
            Qbig[(i-1)*2 + 1][(i-1)*2 + 1] = self.pos_w
            Qbig[(i-1)*2 + 2][(i-1)*2 + 2] = self.vel_w
        end

        -- R_big: R * I_N
        local Rbig = matrix.new(N, N, 0)
        for i = 1, N do Rbig[i][i] = self.R end

        -- D matrix (first-difference operator) and S * I_N
        local Dmat = matrix.new(N, N, 0)
        local Sbig = matrix.new(N, N, 0)
        for i = 1, N do
            Dmat[i][i] = 1
            if i > 1 then Dmat[i][i-1] = -1 end
            Sbig[i][i] = self.S
        end
        -- DT_S_D = D' * S * D  (chained __mul, left-to-right)
        local DT_S_D = Dmat:transpose() * Sbig * Dmat

        -- Linear part of the rate penalty:  -S * u_prev on the first row
        local S_lin = matrix.new(N, 1, 0)
        S_lin[1][1] = -self.S * self.u_prev

        -- Hessian H = Phi'*Q*Phi + Rbig + DT_S_D + tiny regularization
        local PhiT  = Phi:transpose()
        local PhiTQ = PhiT * Qbig
        local H     = (PhiTQ * Phi) + Rbig
        H = H + DT_S_D
        -- Tikhonov regularization (1e-6 * I)
        local reg = matrix.new(N, N, function(r, c) return (r == c) and 1e-6 or 0 end)
        H = H + reg

        -- err_seq = rseq - lift  (cell-by-cell; library has no `sub` shortcut
        -- for our use-case that's any cleaner than a manual loop here).
        local err_seq = matrix.new(2*N, 1, 0)
        for i = 1, 2*N do
            err_seq[i][1] = rseq[i][1] - lift[i][1]
        end

        -- g = Phi' * Q * err_seq, then subtract S_lin row-wise
        local g = PhiTQ * err_seq
        for i = 1, N do g[i][1] = g[i][1] - S_lin[i][1] end

        -- Solve H * U = g.  matrix.solve returns (solution, warning).
        local U
        local ok, solved = pcall(matrix.solve, H, g)
        if ok and solved then
            U = solved
        else
            -- Fallback: degrade to a proportional response on the first sample
            U = matrix.new(N, 1, 0)
            U[1][1] = self.pos_w * (self.target - x0[1][1]) * self.dt
        end

        -- First control, clamped to actuator range
        local u_opt = U[1][1] or 0
        if u_opt < self.u_min then u_opt = self.u_min end
        if u_opt > self.u_max then u_opt = self.u_max end

        -- ---- Cost decomposition (predicted, for the gains graph) ----
        local X_pred = (Phi * U) + lift
        local track, eff, rate = 0, 0, 0
        for i = 1, N do
            local ep = X_pred[(i-1)*2+1][1] - rseq[(i-1)*2+1][1]
            local ev = X_pred[(i-1)*2+2][1] - rseq[(i-1)*2+2][1]
            track = track + self.pos_w * ep*ep + self.vel_w * ev*ev
            eff   = eff   + self.R     * U[i][1] * U[i][1]
        end
        local prev = self.u_prev
        for i = 1, N do
            local du = U[i][1] - prev
            rate = rate + self.S * du * du
            prev = U[i][1]
        end
        self.cost_track = track
        self.cost_eff   = eff
        self.cost_rate  = rate

        -- Predicted future-position trajectory (for graph overlay)
        self.traj_pos = { x0[1][1] }
        for i = 1, N do
            self.traj_pos[i+1] = X_pred[(i-1)*2+1][1]
        end

        -- Save what we are actually applying
        self.u_prev = u_opt

        return u_opt, {
            tracking = track,
            effort   = eff,
            rate     = rate,
            traj     = self.traj_pos,
            U        = U,
            target   = self.target,
        }
    end

    return self
end

return mpc
