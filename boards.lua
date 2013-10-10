local _M = {}

local io = require 'io'
local math = require 'math'
local table = require 'table'
local lfs = require 'lfs'
local pathlib = require 'path'
local gerber = require 'gerber'
local excellon = require 'excellon'
local bom = require 'bom'
local dump = require 'dump'
local crypto = require 'crypto'

local region = require 'boards.region'
local drawing = require 'boards.drawing'
local templates = require 'boards.templates'
local pathmerge = require 'boards.pathmerge'
local manipulation = require 'boards.manipulation'
local panelization = require 'boards.panelization'

pathlib.install()

local unpack = unpack or table.unpack

------------------------------------------------------------------------------

-- all positions are in picometers
local aperture_scales = {
	IN_pm = 25400000000,
	MM_pm =  1000000000,
	IN_mm = 25.4,
	MM_mm =  1,
}

local circle_steps = 64

local function generate_aperture_path(aperture, board_unit)
	local shape = aperture.shape
	local macro = aperture.macro
	if not shape and not macro then
		return
	end
	local parameters = aperture.parameters
	local scale_name = aperture.unit..'_'..board_unit
	local scale = assert(aperture_scales[scale_name], "unsupported aperture scale "..scale_name)
	
	local path
	local path
	if shape=='circle' then
		local d,hx,hy = unpack(parameters)
		assert(d, "circle apertures require at least 1 parameter")
		assert(not hx and not hy, "circle apertures with holes are not yet supported")
		path = {concave=true}
		if d ~= 0 then
			local r = d / 2 * scale
			for i=0,circle_steps do
				if i==circle_steps then i = 0 end -- :KLUDGE: sin(2*pi) is not zero, but an epsilon, so we force it
				local a = math.pi * 2 * (i / circle_steps)
				table.insert(path, {x=r*math.cos(a), y=r*math.sin(a)})
			end
		end
	elseif shape=='rectangle' then
		local x,y,hx,hy = unpack(parameters)
		assert(x and y, "rectangle apertures require at least 2 parameters")
		assert(not hx and not hy, "rectangle apertures with holes are not yet supported")
		path = {
			concave=true,
			{x=-x/2*scale, y=-y/2*scale},
			{x= x/2*scale, y=-y/2*scale},
			{x= x/2*scale, y= y/2*scale},
			{x=-x/2*scale, y= y/2*scale},
			{x=-x/2*scale, y=-y/2*scale},
		}
	elseif shape=='obround' then
		assert(circle_steps % 2 == 0, "obround apertures are only supported when circle_steps is even")
		local x,y,hx,hy = unpack(parameters)
		assert(x and y, "obround apertures require at least 2 parameters")
		assert(not hx and not hy, "obround apertures with holes are not yet supported")
		path = {concave=true}
		if y > x then
			local straight = (y - x) * scale
			local r = x / 2 * scale
			for i=0,circle_steps/2 do
				local a = math.pi * 2 * (i / circle_steps)
				table.insert(path, {x=r*math.cos(a), y=r*math.sin(a)+straight/2})
			end
			for i=circle_steps/2,circle_steps do
				if i==circle_steps then i = 0 end -- :KLUDGE: sin(2*pi) is not zero, but an epsilon, so we force it
				local a = math.pi * 2 * (i / circle_steps)
				table.insert(path, {x=r*math.cos(a), y=r*math.sin(a)-straight/2})
			end
			table.insert(path, {x=r, y=straight/2})
		else
			local straight = (x - y) * scale
			local r = y / 2 * scale
			for i=0,circle_steps/2 do
				local a = math.pi * 2 * (i / circle_steps)
				table.insert(path, {x=r*math.sin(a)+straight/2, y=-r*math.cos(a)})
			end
			for i=circle_steps/2,circle_steps do
				if i==circle_steps then i = 0 end -- :KLUDGE: sin(2*pi) is not zero, but an epsilon, so we force it
				local a = math.pi * 2 * (i / circle_steps)
				table.insert(path, {x=r*math.sin(a)-straight/2, y=-r*math.cos(a)})
			end
			table.insert(path, {x=straight/2, y=-r})
		end
	elseif shape=='polygon' then
		local d,steps,angle,hx,hy = unpack(parameters)
		assert(d and steps, "polygon apertures require at least 2 parameter")
		angle = angle or 0
		assert(not hx and not hy, "polygon apertures with holes are not yet supported")
		path = {concave=true}
		if d ~= 0 then
			local r = d / 2 * scale
			for i=0,steps do
				if i==steps then i = 0 end -- :KLUDGE: sin(2*pi) is not zero, but an epsilon, so we force it
				local a = math.pi * 2 * (i / steps) + math.rad(angle)
				table.insert(path, {x=r*math.cos(a), y=r*math.sin(a)})
			end
		end
	elseif macro then
		path = macro.chunk(unpack(parameters or {}))
		for _,point in ipairs(path) do
			point.x = point.x * scale
			point.y = point.y * scale
		end
	else
		error("unsupported aperture shape "..tostring(shape))
	end
	
	aperture.path = path
end

------------------------------------------------------------------------------

local path_scales = {
	pm = 1,
	mm = 1e-9,
}

local function load_image(path, type, unit, template)
	print("loading "..tostring(path))
	local image
	if type=='drill' then
		image = excellon.load(path)
	elseif type=='bom' then
		image = bom.load(path, template.bom)
	else
		image = gerber.load(path)
	end
	
	-- scale the path data (sub-modules output picometers)
	local scale = assert(path_scales[unit], "unsupported board output unit "..tostring(unit))
	if scale ~= 1 then
		local k = 0
		for _,layer in ipairs(image.layers) do
			for _,path in ipairs(layer) do
				for _,point in ipairs(path) do
					point.x = point.x * scale
					point.y = point.y * scale
					if point.i then point.i = point.i * scale end
					if point.j then point.j = point.j * scale end
					k = k + 1
				end
			end
		end
	end
	
	-- collect apertures
	local apertures = {}
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			local aperture = path.aperture
			if aperture and not apertures[aperture] then
				apertures[aperture] = true
			end
		end
	end
	
	-- generate aperture paths
	for aperture in pairs(apertures) do
		generate_aperture_path(aperture, unit)
	end
	
	-- compute extents
	for aperture in pairs(apertures) do
		if not aperture.extents then
			aperture.extents = region()
			if aperture.path then
				for _,point in ipairs(aperture.path) do
					aperture.extents = aperture.extents + point
				end
			end
		end
	end
	image.center_extents = region()
	image.extents = region()
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			path.center_extents = region()
			for _,point in ipairs(path) do
				path.center_extents = path.center_extents + point
			end
			path.extents = region(path.center_extents)
			local aperture = path.aperture
			if aperture and not aperture.extents.empty then
				path.extents = path.extents * aperture.extents
			end
			image.center_extents = image.center_extents + path.center_extents
			image.extents = image.extents + path.extents
		end
	end
	
	return image
end

local function save_image(image, path, type, unit, template)
	print("saving "..tostring(path))
	assert(unit == 'pm', "saving scaled images is not yet supported")
	if type=='drill' then
		return excellon.save(image, path)
	elseif type=='bom' then
		return bom.save(image, path, template.bom)
	else
		return gerber.save(image, path)
	end
end

------------------------------------------------------------------------------

function _M.load(path, options)
	if not options then options = {} end
	
	local board = {}
	
	board.unit = options.unit or 'pm'
	local template = templates.default_template -- make that configurable
	board.template = template
	
	-- single file special case
	if type(path)=='string' and lfs.attributes(path, 'mode') then
		path = { path }
	end
	
	-- locate files
	local paths = {}
	local extensions = {}
	if type(path)~='table' and lfs.attributes(path, 'mode') then
		path = { path }
	end
	if type(path)=='table' then
		for _,path in ipairs(path) do
			path = pathlib.split(path)
			local found = false
			for image,patterns in pairs(template.patterns) do
				if type(patterns)=='string' then patterns = { patterns } end
				for _,pattern in ipairs(patterns) do
					local lpattern = '^'..pattern:gsub('[%%%.()]', {
						['.'] = '%.',
						['('] = '%(',
						[')'] = '%)',
						['%'] = '(.*)',
					})..'$'
					local basename = path.file:lower():match(lpattern)
					if basename then
						paths[image] = path
						extensions[image] = pattern
						found = true
						break
					end
				end
				if found then
					break
				end
			end
			if not found then
				print("cannot guess type of file "..tostring(path))
			end
		end
	else
		path = pathlib.split(path)
		local files = {}
		for file in lfs.dir(path.dir) do
			files[file:lower()] = file
		end
		for image,patterns in pairs(template.patterns) do
			if type(patterns)=='string' then patterns = { patterns } end
			for _,pattern in ipairs(patterns) do
				local file = files[pattern:gsub('%%', path.file):lower()]
				if file then
					paths[image] = path.dir / file
					extensions[image] = pattern
					found = true
					break
				end
			end
		end
	end
	if next(paths)==nil then
		return nil,"no image found"
	end
	board.extensions = extensions
	
	-- determine file hashes
	local hashes = {}
	for type,path in pairs(paths) do
		local file = assert(io.open(path, "rb"))
		local content = assert(file:read('*all'))
		assert(file:close())
		local hash = crypto.evp.digest('md5', content):lower()
		hashes[type] = hash
	end
	board.hashes = hashes
	
	-- load image metadata
	local images = {}
	for type,path in pairs(paths) do
		local hash = hashes[type]
		local image = load_image(path, type, board.unit, board.template)
		images[type] = image
	end
	board.images = images
	
	-- compute board extents
	board.extents = region()
	for type,image in pairs(images) do
		if type=='milling' or type=='drill' then
			-- only extend to the points centers
			board.extents = board.extents + image.center_extents
		elseif (type=='top_silkscreen' or type=='bottom_silkscreen') and not options.silkscreen_extends_board then
			-- don't extend with these
		elseif type=='bom' then
			-- BOM is parts logical centers, unrelated to board actual dimension
		else
			board.extents = board.extents + image.extents
		end
	end
	if board.extents.empty then
		return nil,"board is empty"
	end
	
	return board
end

function _M.save(board, path)
	if pathlib.type(path) ~= 'path' then
		path = pathlib.split(path)
	end
	for type,image in pairs(board.images) do
		local pattern = assert(board.extensions[type], "no extension pattern for file of type "..type)
		local path = path.dir / pattern:gsub('%%', path.file)
		local success,msg = save_image(image, path, type, board.unit, board.template)
		if not success then return nil,msg end
	end
	return true
end

------------------------------------------------------------------------------

local function find_image_outline(image)
	-- find path with largest area
	local amax,lmax,pmax = -math.huge
	for l,layer in ipairs(image.layers) do
		for p,path in ipairs(layer) do
			local width = path.extents.right - path.extents.left
			local height = path.extents.top - path.extents.bottom
			local a = width * height
			if a > amax then
				amax,lmax,pmax = a,l,p
			end
		end
	end
	if not lmax or not pmax then return nil end
	local path = image.layers[lmax][pmax]
	-- check that the path has the same extents as the image
	if path.extents.left ~= image.extents.left
		or path.extents.right ~= image.extents.right
		or path.extents.bottom ~= image.extents.bottom
		or path.extents.top ~= image.extents.top then
		return nil
	end
	-- check that the path is long enough to enclose a region
	if #path < 3 then
		return nil
	end
	-- check that the path is closed
	if path[1].x ~= path[#path].x or path[1].y ~= path[#path].y then
		return nil
	end
	-- check that path is a line, not a region
	if not path.aperture then
		return nil
	end
	-- :TODO: check that all other paths are within the outline
	
	return path,lmax,pmax
end

local ignore_outline = {
	top_soldermask = true,
	bottom_soldermask = true,
}
_M.ignore_outline = ignore_outline

function _M.find_board_outlines(board)
	local outlines = {}
	-- gen raw list
	local max_area = -math.huge
	for type,image in pairs(board.images) do
		if not ignore_outline[type] then
			local path,ilayer,ipath = find_image_outline(image)
			if path then
				local area = (path.center_extents.right - path.center_extents.left) * (path.center_extents.top - path.center_extents.bottom)
				max_area = math.max(max_area, area)
				outlines[type] = {path=path, ilayer=ilayer, ipath=ipath, area=area}
			end
		end
	end
	-- filter the list
	for type,data in pairs(outlines) do
		-- igore all but the the largest ones
		if data.area < max_area then
			outlines[type] = nil
		end
	end
	return outlines
end

------------------------------------------------------------------------------

local function merge_image_apertures(image)
	-- list apertures
	local apertures = {}
	local aperture_order = {}
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			local aperture = path.aperture
			if aperture then
				local s = assert(dump.tostring(aperture))
				if apertures[s] then
					aperture = apertures[s]
					path.aperture = aperture
				else
					apertures[s] = aperture
					table.insert(aperture_order, aperture)
				end
			end
		end
	end
	
	-- list macros
	local macros = {}
	local macro_order = {}
	for _,aperture in ipairs(aperture_order) do
		local macro = aperture.macro
		if macro then
			local s = dump.tostring(macro)
			if macros[s] then
				aperture.macro = macros[s]
			else
				macros[s] = macro
				table.insert(macro_order, macro)
			end
		end
	end
end

local function merge_board_apertures(board)
	for _,image in pairs(board.images) do
		merge_image_apertures(image)
	end
end

function _M.merge_apertures(board)
	merge_board_apertures(board)
end

------------------------------------------------------------------------------

local function value_to_pm(value, unit)
	assert(value:match('^(%d+)%.(%d+)$') or value:match('^(%d+)$'), "malformed number '"..value.."'")
	if unit=='pm' then
		return assert(tonumber(value), "number conversion failed")
	elseif unit=='mm' then
		-- simply move the dot 9 digits to the right
		local i,dm = value:match('^(%d+)%.(%d+)$')
		local dp
		if i and dm then
			if #dm < 9 then
				dp = '0'
				dm = dm..string.rep('0', 9 - #dm)
			else
				dp = dm:sub(10)
				dm = dm:sub(1, 9)
			end
		else
			i = value
			dp = '0'
			dm = '000000000'
		end
		return assert(tonumber(i..dm..'.'..dp), "number conversion failed")
	elseif unit=='in' then
		-- move the dot 8 digits to the right, and multiply by 254
		local i,dm = value:match('^(%d+)%.(%d+)$')
		local dp
		if i and dm then
			if #dm < 8 then
				dp = '0'
				dm = dm..string.rep('0', 8 - #dm)
			else
				dp = dm:sub(9)
				dm = dm:sub(1, 8)
			end
		else
			i = value
			dp = '0'
			dm = '00000000'
		end
		return 254 * assert(tonumber(i..dm..'.'..dp), "number conversion failed")
	else
		error("invalid unit '"..tostring(unit).."'")
	end
end

function _M.parse_distances(str)
	local numbers = {}
	for sign,value,unit in str:gmatch('([+-]?)([%d.]+)(%w*)') do
		if unit=='' then unit = 'mm' end
		local n = value_to_pm(value, unit)
		if sign=='-' then n = -n end
		table.insert(numbers, n)
	end
	return table.unpack(numbers)
end

------------------------------------------------------------------------------

_M.offset = manipulation.offset_board
_M.rotate180 = manipulation.rotate180_board
_M.merge = manipulation.merge_boards

_M.draw_path = drawing.draw_path
_M.empty_board = panelization.empty_board
_M.panelize = panelization.panelize

_M.merge_image_paths = pathmerge.merge_image_paths

------------------------------------------------------------------------------

return _M
