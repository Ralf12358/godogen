extends SceneTree
## Compare two side-by-side PNGs and report which row ranges differ.
## Used to verify that successive rig-motion captures differ by the
## expected amount (see vr-verification.md for budgets).

func _init() -> void:
	if OS.get_cmdline_user_args().size() < 2:
		print("usage: -- a.png b.png")
		quit(1)
		return
	var a: Image = Image.load_from_file(OS.get_cmdline_user_args()[0])
	var b: Image = Image.load_from_file(OS.get_cmdline_user_args()[1])
	if a == null or b == null:
		print("could not load images")
		quit(1)
		return
	if a.get_size() != b.get_size():
		print("size mismatch: a=%s b=%s" % [a.get_size(), b.get_size()])
		quit(1)
		return
	# Count differing pixels per row.
	var w: int = a.get_width()
	var h: int = a.get_height()
	var total_diff: int = 0
	var rows_with_diff: int = 0
	for y in range(h):
		var row_diff: int = 0
		for x in range(w):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				row_diff += 1
		if row_diff > 0:
			rows_with_diff += 1
			total_diff += row_diff
	print("rows_with_diff=%d/%d total_diff_pixels=%d (%.2f%%)" % [
		rows_with_diff, h, total_diff, 100.0 * total_diff / (w * h)])
	quit(0)
