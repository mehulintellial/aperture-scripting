local os = require 'os'
local fs = require 'lfs'
local gerber = require 'gerber'
local excellon = require 'excellon'
local boards = require 'boards'
local extents = require 'boards.extents'
local manipulation = require 'boards.manipulation'
local interpolation = require 'boards.interpolation'

local function log(s, ...)
	print('- '..s, ...)
end

------------------------------------------------------------------------------

local function rmdir(dir)
	return os.execute('rm -rf '..dir)
end

local function diff(a, b)
	return os.execute('diff -durN '..a..' '..b)
end

------------------------------------------------------------------------------

log 'load gerber'
assert(gerber.load("test/example2.grb"))
log 'load board'
assert(boards.load("test/simple/simple"))

log 'copy gerber'
os.remove('test/copy.grb')
assert(gerber.save(assert(gerber.load("test/example2.grb")), "test/copy.grb"))
assert(diff('test/copy.grb.expected', 'test/copy.grb'))

log 'copy excellon'
os.remove('test/copy.drl')
assert(excellon.save(assert(excellon.load("test/example.drl")), "test/copy.drl"))
assert(diff('test/copy.drl.expected', 'test/copy.drl'))

log 'copy board'
assert(rmdir('test/simple.copy'))
assert(fs.mkdir('test/simple.copy'))
assert(boards.save(assert(boards.load("test/simple/simple")), "test/simple.copy/simple"))
assert(diff('test/simple.copy.expected', 'test/simple.copy'))

log 'copy copy of board'
assert(rmdir('test/simple.copy2'))
assert(fs.mkdir('test/simple.copy2'))
assert(boards.save(assert(boards.load("test/simple.copy/simple")), "test/simple.copy2/simple"))
assert(diff('test/simple.copy.expected', 'test/simple.copy2'))

log 'null offset' -- should be a copy
assert(rmdir('test/simple.offset-0-0'))
assert(fs.mkdir('test/simple.offset-0-0'))
assert(boards.save(assert(manipulation.offset_board(assert(boards.load("test/simple/simple")), 0, 0)), "test/simple.offset-0-0/simple"))
assert(diff('test/simple.copy.expected', 'test/simple.offset-0-0'))
log 'move one inch to the right'
assert(rmdir('test/simple.offset-1in-0'))
assert(fs.mkdir('test/simple.offset-1in-0'))
assert(boards.save(assert(manipulation.offset_board(assert(boards.load("test/simple/simple")), 254e8, 0)), "test/simple.offset-1in-0/simple"))
assert(diff('test/simple.offset-1in-0.expected', 'test/simple.offset-1in-0'))

log 'manipulate excellon'
local a = assert(boards.load_image('test/example.drl'))
local b = assert(manipulation.offset_image(a, 254e9, 0))
local c = assert(manipulation.merge_images(a, b))
assert(boards.save_image(c, 'test/merged.drl', 'excellon'))
assert(diff('test/merged.drl.expected', 'test/merged.drl'))
assert(rmdir('test/simple.merge-a'))
assert(fs.mkdir('test/simple.merge-a'))
log 'manipulate board'
local a = assert(boards.load('test/simple/simple', {keep_outlines_in_images=true}))
-- move one inch to the right
local b = assert(manipulation.offset_board(a, 254e8, 0))
local c = assert(manipulation.merge_boards(a, b))
boards.merge_apertures(c)
assert(boards.save(c, 'test/simple.merge-a/simple'))
assert(diff('test/simple.merge-a.expected', 'test/simple.merge-a'))

------------------------------------------------------------------------------

local image = boards.load_image('test/example2.grb')
log 'offset gerber'
manipulation.offset_image(image, 3, 4)
log 'rotate gerber (0)'
manipulation.rotate_image(image, 0)
log 'rotate gerber (90)'
manipulation.rotate_image(image, 90)
log 'rotate gerber (180)'
manipulation.rotate_image(image, 180)
log 'rotate gerber (270)'
manipulation.rotate_image(image, 270)

log 'rotate board'
local board = assert(boards.load('test/simple/simple'))
board = assert(manipulation.rotate_board(board, 90))
assert(boards.save(board, 'test/output/tmp'))

------------------------------------------------------------------------------

log 'check all apertures'
local board = assert(boards.load("test/apertures"))
boards.generate_aperture_paths(board)
log 'rotate all apertures'
manipulation.rotate_board(board, 0)
manipulation.rotate_board(board, 90)
manipulation.rotate_board(board, 180)
manipulation.rotate_board(board, 270)

log 'compute aperture extents'
local apertures = {}
for _,image in pairs(board.images) do
	for _,layer in ipairs(image.layers) do
		for  _,path in ipairs(layer) do
			if path.aperture then
				apertures[path.aperture] = true
			end
		end
	end
end
for aperture in pairs(apertures) do
	extents.compute_aperture_extents(aperture)
end

log 'merge apertures'
boards.merge_apertures(board)

log 'compute board extents (with outline)'
extents.compute_board_extents(board)
log 'compute board extents (without outline)'
board.outline = nil
extents.compute_board_extents(board)

log 'check rotatable apertures'
local board = assert(boards.load("test/rotate"))
boards.generate_aperture_paths(board)
log 'rotate rotatable apertures'
manipulation.rotate_board(board, 0)
manipulation.rotate_board(board, 90)
manipulation.rotate_board(board, 180)
manipulation.rotate_board(board, 270)
manipulation.rotate_board(board, 17)
manipulation.rotate_board(board, 97)
manipulation.rotate_board(board, 181)
manipulation.rotate_board(board, 271)

------------------------------------------------------------------------------

log 'check all paths'
local board = assert(boards.load("test/paths"))
log 'interpolate paths'
interpolation.interpolate_board_paths(board, 0.01e-9)

log 'load paths as mm'
local board = assert(boards.load("test/paths", {unit='mm'}))

------------------------------------------------------------------------------

log 'run example panels'
fs.chdir('doc/examples')

dofile('save.cfg')
dofile('rotate.cfg')
dofile('panel.cfg')
dofile('panel-rotate.cfg')
dofile('empty.cfg')
dofile('panel-panel.cfg')
dofile('panel-layout.cfg')
dofile('drawing-fiducials.cfg')
dofile('drawing-text.cfg')
dofile('empty-save.cfg')

------------------------------------------------------------------------------

log 'all tests passed successfully'
