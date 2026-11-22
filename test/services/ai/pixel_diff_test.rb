require "test_helper"

class Ai::PixelDiffTest < ActiveSupport::TestCase
  test "decodes a PNG to grayscale dimensions and pixels" do
    png = MiniPng.png(width: 3, height: 2, rects: [ [ 1, 0, 1, 1 ] ])
    decoded = Ai::PixelDiff::Png.grayscale(png)
    assert_equal 3, decoded[:width]
    assert_equal 2, decoded[:height]
    assert_equal 6, decoded[:gray].length
    # label pixel black, background white
    assert_equal 0, decoded[:gray].getbyte(1)
    assert_equal 255, decoded[:gray].getbyte(0)
  end

  test "returns nil for undecodable input" do
    assert_nil Ai::PixelDiff::Png.grayscale("not a png")
    assert_nil Ai::PixelDiff::Png.grayscale("not a png\x00\x01\x02")
  end

  test "derives one mask box from a single removed label rectangle" do
    labeled = MiniPng.png(width: 40, height: 30, rects: [ [ 10, 10, 8, 6 ] ])
    clean = MiniPng.png(width: 40, height: 30)
    masks = Ai::PixelDiff.masks(labeled_bytes: labeled, clean_bytes: clean)

    assert_equal 1, masks.size
    assert_in_delta 0.25, masks.first["x"], 0.03
    assert_in_delta 0.3333, masks.first["y"], 0.05
    assert_in_delta 0.2, masks.first["w"], 0.05
    assert_in_delta 0.2, masks.first["h"], 0.08
  end

  test "merges nearby letter blobs into one word box" do
    # A word of two letters separated by a small gap, plus a far-away label.
    labeled = MiniPng.png(width: 100, height: 60,
                          rects: [ [ 5, 5, 4, 8 ], [ 11, 5, 4, 8 ], [ 80, 40, 4, 8 ] ])
    clean = MiniPng.png(width: 100, height: 60)
    masks = Ai::PixelDiff.masks(labeled_bytes: labeled, clean_bytes: clean)

    assert_equal 2, masks.size
    word = masks.first
    assert_in_delta 0.05, word["x"], 0.04
    assert_in_delta 1.0, (word["x"] + word["w"]) * 100 - 15, 3 # spans both letters
  end

  test "identical or dimension-mismatched pairs yield no masks" do
    same = MiniPng.png(width: 40, height: 30, rects: [ [ 10, 10, 8, 6 ] ])
    assert_equal [], Ai::PixelDiff.masks(labeled_bytes: same, clean_bytes: same)
    mismatch = MiniPng.png(width: 41, height: 30)
    assert_equal [], Ai::PixelDiff.masks(labeled_bytes: same, clean_bytes: mismatch)
  end

  test "ignores redraw noise smaller than the minimum blob area" do
    labeled = MiniPng.png(width: 60, height: 40, rects: [ [ 5, 5, 4, 4 ] ])
    clean = MiniPng.png(width: 60, height: 40)
    assert_equal [], Ai::PixelDiff.masks(labeled_bytes: labeled, clean_bytes: clean)
  end
end
