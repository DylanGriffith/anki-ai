require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]

  # Saves a screenshot as feature evidence in screenshots/.
  def evidence(name)
    path = Rails.root.join("screenshots", "#{name}.png")
    FileUtils.mkdir_p(File.dirname(path))
    page.save_screenshot(path.to_s)
    Rails.logger.info("Screenshot: #{path}")
  end
end
