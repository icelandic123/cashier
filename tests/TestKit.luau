--!strict
-- A tiny test runner for Lune. Tests may yield.

local TestKit = {}

type Test = { name: string, fn: () -> () }
local tests: { Test } = {}
local prefix: { string } = {}

function TestKit.describe(name: string, fn: () -> ())
	table.insert(prefix, name)
	fn()
	table.remove(prefix)
end

function TestKit.it(name: string, fn: () -> ())
	local full = table.concat(prefix, " > ")
	table.insert(tests, { name = if full ~= "" then `{full} > {name}` else name, fn = fn })
end

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

function TestKit.expect(actual: any)
	local api = {}
	function api.toBe(expected: any)
		if actual ~= expected then
			error(`expected {show(actual)} to be {show(expected)}`, 2)
		end
	end
	function api.never(expected: any)
		if actual == expected then
			error(`expected {show(actual)} not to be {show(expected)}`, 2)
		end
	end
	function api.toBeTruthy()
		if not actual then
			error(`expected {show(actual)} to be truthy`, 2)
		end
	end
	function api.toBeNil()
		if actual ~= nil then
			error(`expected {show(actual)} to be nil`, 2)
		end
	end
	function api.toContain(fragment: string)
		if type(actual) ~= "string" or not string.find(actual, fragment, 1, true) then
			error(`expected {show(actual)} to contain {show(fragment)}`, 2)
		end
	end
	function api.toThrow(fragment: string?)
		local ok, err = pcall(actual)
		if ok then
			error("expected function to throw", 2)
		end
		if fragment and not string.find(tostring(err), fragment, 1, true) then
			error(`expected error {show(tostring(err))} to contain {show(fragment)}`, 2)
		end
	end
	return api
end

-- Lets spawned threads and zero-delay timers run.
function TestKit.flush(cycles: number?)
	for _ = 1, cycles or 5 do
		task.wait()
	end
end

function TestKit.run(): number
	local failed = 0
	local started = os.clock()
	for _, test in tests do
		local ok, err = xpcall(test.fn, debug.traceback)
		if ok then
			print(`  ok   {test.name}`)
		else
			failed += 1
			print(`  FAIL {test.name}\n{err}`)
		end
	end
	print(string.format("\n%d passed, %d failed (%.2fs)", #tests - failed, failed, os.clock() - started))
	return failed
end

return TestKit
