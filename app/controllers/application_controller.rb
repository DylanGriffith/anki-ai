class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user

  private

  def current_user
    @current_user ||= session[:user_id] ? User.find_by(id: session[:user_id]) : nil
  end

  def require_login
    redirect_to login_path, alert: "Please sign in first." unless current_user
  end
end
