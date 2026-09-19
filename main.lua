--- Minimal PDF image preview: pdftoppm page -> jpeg -> ya.image_show.
--- One page per peek (skip = page-1); meta strip on the bottom row.
--- @since 26.9.1
local M = {}

local RENDER_W = 600

local function fail(job, s)
	ya.err("pdfview: " .. s)
	pcall(function()
		ya.preview_widget(job, ui.Text.parse(s):area(job.area))
	end)
end

local function page_count(pdf_path)
	local out = Command("pdfinfo"):arg(tostring(pdf_path)):output()
	if not (out and out.status.success) then
		return 1
	end
	return tonumber(out.stdout:match("Pages:%s*(%d+)")) or 1
end

-- Render one page into the skip-keyed yazi cache. A directory lock keeps the
-- hover double-render (preloader + peek) from racing the same file; a peer
-- finishing first satisfies us immediately.
local function render_page(job, page)
	local root = ya.file_cache { file = job.file, skip = page - 1 }
	if not root then
		return nil
	end
	local cache = Url(tostring(root) .. ".jpg")
	if fs.cha(cache) then
		return cache
	end

	local lock = tostring(cache) .. ".lock"
	local deadline = ya.time() + 2
	local held = false
	while ya.time() < deadline do
		if fs.create("dir", lock) then
			held = true
			break
		end
		if fs.cha(cache) then
			return cache
		end
		ya.sleep(0.02)
	end

	local child = Command("pdftoppm"):arg({
		"-jpeg", "-singlefile",
		"-f", tostring(page), "-l", tostring(page),
		"-scale-to-x", tostring(RENDER_W), "-scale-to-y", "-1",
		tostring(job.file.url), tostring(root),
	})
		:stdin(Command.NULL)
		:stdout(Command.NULL)
		:stderr(Command.PIPED)
		:spawn()

	local ok, out = false, nil
	if child then
		ok, out = true, { child:wait_with_output() }
	end
	os.remove(lock)

	if not (ok and out[1] and out[1].status.success) or not fs.cha(cache) then
		fs.remove("file", cache)
		return nil
	end
	return cache
end

function M:preload(job)
	if job.mime ~= "application/pdf" then
		return false
	end
	return render_page(job, 1) ~= nil
end

function M:peek(job)
	if job.mime ~= "application/pdf" then
		return fail(job, "pdf.yazi: not a pdf")
	end

	local pages = page_count(tostring(job.file.url))
	local page = math.max(1, math.min((job.skip or 0) + 1, pages))

	local cache = render_page(job, page)
	if not cache then
		return fail(job, "pdf.yazi: render failed (page " .. page .. ")")
	end

	-- image fills all but the last row; the last row is the metadata strip
	ya.image_show(Url(cache), ui.Rect {
		x = job.area.x, y = job.area.y,
		w = job.area.w, h = math.max(1, job.area.h - 1),
	})

	local cha = job.file.cha
	local meta = string.format(
		"%s | %s | %s",
		job.mime or "application/pdf",
		ya.readable_size(cha.len),
		os.date("%y/%m/%d %H:%M", cha.mtime)
	)
	local counter = string.format("Page %d/%d", page, pages)
	local budget = job.area.w - #counter - 2
	if #meta > budget then
		meta = ".." .. meta:sub(-(math.max(1, budget - 2)))
	end
	local gap = string.rep(" ", math.max(1, job.area.w - #meta - #counter))
	ya.preview_widget(job, ui.Text({
		ui.Line({ ui.Span(meta), ui.Span(gap), ui.Span(counter) }),
	}):area(ui.Rect {
		x = job.area.x, y = job.area.y + job.area.h - 1,
		w = job.area.w, h = 1,
	}))
end

return {
	preload = function(job) return M:preload(job) end,
	peek = function(job) return M:peek(job) end,
}
