-- Pure-maths tests for RVFinePlank. Run: lua tests/test_math.lua (from repo root)
-- No UE, no mocks — just arithmetic, which is where snapping and calibration bugs hide.

package.path = "RVFinePlank/Scripts/?.lua;" .. package.path
local m = require("rvfp_math")

local passed, failed, failures = 0, 0, {}
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS  " .. name)
    else
        failed = failed + 1; failures[#failures + 1] = name
        print("  FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

print("\n=== RVFinePlank maths ===\n")

print("[clamp / round]")
check("clamp low",  m.clamp(-5, 0, 10) == 0)
check("clamp high", m.clamp(50, 0, 10) == 10)
check("clamp pass", m.clamp(5, 0, 10) == 5)
check("round half up",   m.round(2.5) == 3)
check("round negative",  m.round(-2.4) == -2)

print("\n[snap_to]")
check("snaps down to grid", near(m.snap_to(14.0, 15), 15.0), m.snap_to(14.0, 15))
check("snaps up to grid",   near(m.snap_to(7.0, 15), 0.0), m.snap_to(7.0, 15))
check("snaps to 45",        near(m.snap_to(40.0, 15), 45.0))
check("negative snaps",     near(m.snap_to(-22.0, 15), -15.0), m.snap_to(-22.0, 15))
check("already on grid",    near(m.snap_to(30.0, 15), 30.0))
check("step 0 is identity", near(m.snap_to(13.7, 0), 13.7))
check("nil step is identity", near(m.snap_to(13.7, nil), 13.7))

print("\n[snap_delta]")
check("delta to nearest",       near(m.snap_delta(14.0, 15), 1.0), m.snap_delta(14.0, 15))
check("delta is negative when above", near(m.snap_delta(16.0, 15), -1.0), m.snap_delta(16.0, 15))
check("zero when on grid",      m.snap_delta(30.0, 15) == 0)
check("zero within epsilon",    m.snap_delta(30.0000001, 15) == 0)
check("exact midpoint resolves", near(m.snap_delta(7.5, 15), 7.5), m.snap_delta(7.5, 15))

print("\n[angle normalisation]")
check("norm 370 -> 10",    near(m.norm180(370), 10))
check("norm 190 -> -170",  near(m.norm180(190), -170))
check("norm -190 -> 170",  near(m.norm180(-190), 170))
check("norm 180 stays",    near(m.norm180(180), 180))
check("delta across wrap", near(m.angle_delta(350, 10), 20), m.angle_delta(350, 10))
check("delta reverse wrap",near(m.angle_delta(10, 350), -20), m.angle_delta(10, 350))

print("\n[sensitivity measurement]")
check("basic ratio",        near(m.sensitivity(0, 0.1, 0.05), 2.0), m.sensitivity(0, 0.1, 0.05))
check("negative probe",     near(m.sensitivity(0, -0.1, -0.05), 2.0))
check("no movement -> nil", m.sensitivity(5, 5, 0.05) == nil)
check("zero probe -> nil",  m.sensitivity(0, 1, 0) == nil)
check("nil probe -> nil",   m.sensitivity(0, 1, nil) == nil)
check("inverted -> nil",    m.sensitivity(0, -0.1, 0.05) == nil)
check("implausibly large -> nil", m.sensitivity(0, 1e9, 1e-6) == nil)
check("tiny but real is kept",    near(m.sensitivity(0, 0.001, 0.05), 0.02))

print("\n[unit conversion]")
check("to_input divides",    near(m.to_input(10, 2.0), 5.0))
check("to_real multiplies",  near(m.to_real(5, 2.0), 10.0))
check("round trip",          near(m.to_real(m.to_input(7.3, 2.0), 2.0), 7.3))
check("no sens passes through", near(m.to_input(7.3, nil), 7.3))
check("zero sens passes through", near(m.to_input(7.3, 0), 7.3))

print("\n[off_level]")
check("flat is zero",        near(m.off_level(0, 0), 0))
check("pure pitch",          near(m.off_level(3, 0), 3))
check("pure roll",           near(m.off_level(0, 4), 4))
check("combined is hypot",   near(m.off_level(3, 4), 5))
check("sign independent",    near(m.off_level(-3, -4), 5))
check("wraps before measuring", near(m.off_level(359, 0), 1), m.off_level(359, 0))
check("nil treated as zero", near(m.off_level(nil, nil), 0))

print("\n[axis_endpoints]")
do
    local a, b = m.axis_endpoints({ X = 0, Y = 0, Z = 0 }, { X = 1, Y = 0, Z = 0 }, 100)
    check("endpoints straddle the centre", near(a.X, -50) and near(b.X, 50), a.X .. "/" .. b.X)
    check("other axes untouched", near(a.Y, 0) and near(b.Z, 0))
    local c, d = m.axis_endpoints({ X = 10, Y = 10, Z = 10 }, { X = 0, Y = 0, Z = 1 }, 20)
    check("offset centre respected", near(c.Z, 0) and near(d.Z, 20), c.Z .. "/" .. d.Z)
end

print("\n[span]")
do
    local horiz, drop = m.span({ X = 0, Y = 0, Z = 100 }, { X = 30, Y = 40, Z = 90 })
    check("horizontal distance", near(horiz, 50), horiz)
    check("vertical drop signed", near(drop, -10), drop)
end

print("\n[fmt]")
check("one decimal",  m.fmt(1.26, 1) == "1.3")
check("two decimals", m.fmt(1.254, 2) == "1.25")
check("non-number passes through", m.fmt(nil) == "nil")

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then print("failures: " .. table.concat(failures, ", ")); os.exit(1) end
os.exit(0)
