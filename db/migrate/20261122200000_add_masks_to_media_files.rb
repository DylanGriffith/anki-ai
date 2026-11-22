class AddMasksToMediaFiles < ActiveRecord::Migration[8.1]
  def change
    # Auto-derived image-occlusion mask boxes for AI-generated labeled
    # diagrams: array of { "x", "y", "w", "h" } fractions (0..1) of the image.
    add_column :media_files, :masks, :json
  end
end
