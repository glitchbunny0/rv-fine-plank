--[[ RVFinePlank — pure maths. No UE access, no globals, fully unit-testable.

    Everything here is deliberately free of engine calls so the fiddly parts
    (snapping across the wrap boundary, calibration arithmetic, clamping) can be
    tested exhaustively off-game, where a wrong answer is cheap to find.
--]]

local M = {}

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.round(v)
    return math.floor(v + 0.5)
end

-- Nearest multiple of `step`. Used for angle snapping.
function M.snap_to(v, step)
    if not step or step <= 0 then return v end
    return M.round(v / step) * step
end

-- Signed delta that moves `current` onto the nearest multiple of `step`.
-- Returns 0 when already on a multiple (within eps) so callers can skip a no-op call.
function M.snap_delta(current, step, eps)
    eps = eps or 1e-6
    local target = M.snap_to(current, step)
    local d = target - current
    if math.abs(d) <= eps then return 0 end
    return d
end

-- Normalise an angle to (-180, 180]. Hand-pose accumulators are clamped by the
-- game rather than wrapped, but world rotations we read back are not.
function M.norm180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- Shortest signed rotation from `from` to `to`, respecting wraparound.
function M.angle_delta(from, to)
    return M.norm180(to - from)
end

--[[ Calibration.

    The game multiplies hand-pose input by an unknown sensitivity before
    accumulating. We measure it: apply a known probe delta, observe how far the
    accumulator moved, and the ratio is the sensitivity.

        sens = (after - before) / probe

    Then a request in real degrees becomes  degrees / sens  input units.

    Returns nil when the measurement is unusable — most importantly when the
    accumulator did not move at all, which happens if it is sitting against the
    game's clamp. Callers must handle nil by retrying in the other direction.
--]]
function M.sensitivity(before, after, probe)
    if probe == nil or probe == 0 then return nil end
    local moved = after - before
    if math.abs(moved) < 1e-9 then return nil end          -- clamped, or ignored
    local s = moved / probe
    if s <= 0 then return nil end                          -- inverted or nonsense
    if s > 1e6 or s < 1e-6 then return nil end             -- implausible
    return s
end

-- Convert a request in real units into the game's input units.
-- With no calibration we pass the value through, which keeps the mod usable
-- (just with opaque step sizes) rather than dead.
function M.to_input(real, sens)
    if not sens or sens <= 0 then return real end
    return real / sens
end

-- Convert an accumulator reading into real units.
function M.to_real(input, sens)
    if not sens or sens <= 0 then return input end
    return input * sens
end

-- Format a number for the HUD with a fixed width so the readout does not jitter.
function M.fmt(v, decimals)
    if type(v) ~= "number" then return tostring(v) end
    return string.format("%." .. (decimals or 1) .. "f", v)
end

--[[ Guide geometry.

    Given a world location, a forward unit vector and a length, return the two
    endpoints of a line through the location along that axis. Used to project
    where the plank's long axis points, which is the thing you actually need to
    see when bridging a gap.
--]]
function M.axis_endpoints(loc, fwd, length)
    local half = (length or 0) * 0.5
    return
        { X = loc.X - fwd.X * half, Y = loc.Y - fwd.Y * half, Z = loc.Z - fwd.Z * half },
        { X = loc.X + fwd.X * half, Y = loc.Y + fwd.Y * half, Z = loc.Z + fwd.Z * half }
end

-- Horizontal (world-XY) distance between two points; vertical drop separately.
-- Lets the HUD answer "is this plank actually reaching across, and is it level?"
function M.span(a, b)
    local dx, dy, dz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
    return math.sqrt(dx * dx + dy * dy), dz
end

-- How far from level, in degrees, given a pitch and roll. One number for the HUD.
function M.off_level(pitch, roll)
    local p, r = M.norm180(pitch or 0), M.norm180(roll or 0)
    return math.sqrt(p * p + r * r)
end

return M
