local _M = {}

local io = require 'io'
local table = require 'table'
local string = require 'string'
local gerber = require 'gerber.blocks'

local tool_mt = {}

function tool_mt:__tostring()
	local parameters = {}
	for _,name in ipairs(self.parameters) do
		table.insert(parameters, name..self.parameters[name])
	end
	return string.format('T%02d%s', self.tcode, table.concat(parameters))
end

function _M.tool(tcode, parameters)
	local data = {
		type = 'tool',
		tcode = tcode,
		parameters = parameters,
	}
	return setmetatable(data, tool_mt)
end

local function load_tool(block)
	-- may be a tool definition (in header) or a tool selection (in program)
	local tcode,sparameters = block:match('^T(%d+)(.*)$')
	assert(tcode and sparameters)
	tcode = tonumber(tcode)
	local parameters = {}
	for name,value in string.gmatch(sparameters, '(%a)([%d%.-]+)') do
		parameters[name] = tonumber(value)
		table.insert(parameters, name) -- for order
	end
	return _M.tool(tcode, parameters)
end

local function load_header(block)
	return block
end

local function save_directive(self, long)
	local G = self.G and string.format('G%02d', self.G) or ''
	local X = self.X and 'X'..gerber.save_number(self.X, self.format, long) or ''
	local Y = self.Y and 'Y'..gerber.save_number(self.Y, self.format, long) or ''
	local T = self.T and string.format('T%02d', self.T) or ''
	local M = self.M and string.format('M%02d', self.M) or ''
	return G..X..Y..T..M
end

local directive_mt = {}

function directive_mt:__tostring()
	return save_directive(self)
end

local function load_directive(block, format)
	local directive = setmetatable({type='directive'}, directive_mt)
	for letter,number in block:gmatch('(%a)([0-9+-]+)') do
		if letter:match('[XY]') then
			directive.format = assert(format)
			directive[letter] = gerber.load_number(number, format)
		else
			assert(number:match('^%d%d%d?$'))
			directive[letter] = tonumber(number)
		end
	end
	local short,long = tostring(directive),save_directive(directive, true)
	assert(block == short or block == long, "block '"..block.."' has been converted to '"..short.."' or '"..long.."'")
	return directive
end

function _M.load(filename)
	local file = assert(io.open(filename, 'rb'))
	local content = assert(file:read('*all'))
	assert(file:close())
	
	content = content:gsub('\r', '')

	local data = { headers = {}, tools = {} }
	-- :FIXME: find out how excellon files declare their format
	local format = { integer = 2, decimal = 4, zeroes = 'L' }
	local header = nil
	for block in content:gmatch('[^\n]+') do
		if header then
			if block=='M95' or block=='%' then
				header = false
			else
				if block:match('^T') then
					local tool = load_tool(block)
					data.tools[tool.tcode] = tool
					table.insert(data.headers, tool)
				elseif block:match('^;FILE_FORMAT=') then
					local i,d = block:match('^;FILE_FORMAT=(%d+):(%d+)$')
					format.integer = tonumber(i)
					format.decimal = tonumber(d)
					table.insert(data.headers, load_header(block))
				elseif block=='INCH,LZ' or block=='INCH,TZ' or block=='METRIC,LZ' or block=='METRIC,TZ' then
					local unit,zeroes = block:match('^(.*),(.*)$')
					assert(unit=='INCH', "metric Excellon files are not yet supported")
					if zeroes == 'LZ' then -- header is what is present
						format.zeroes = 'T' -- format is what we omit
					elseif zeroes == 'TZ' then
						format.zeroes = 'L'
					end
					table.insert(data.headers, load_header(block))
				else
					-- this is a very basic parameter parsing
					table.insert(data.headers, load_header(block))
				end
			end
		else
			if block=='%' then
				-- ignore
			elseif block=='M48' then
				header = true
			elseif block:match('^[MXYT]') then
				table.insert(data, load_directive(block, format))
			else
				table.insert(data, block)
			end
		end
	end
	
	return data
end

function _M.save(data, filename)
	local file = assert(io.open(filename, 'wb'))
	if data.headers then
		file:write('%\r\nM48\r\n')
		for _,header in ipairs(data.headers) do
			file:write(tostring(header)..'\r\n')
		end
		file:write('%\r\n')
	end
	for _,block in ipairs(data) do
		file:write(tostring(block)..'\r\n')
	end
	assert(file:close())
	return true
end

return _M
