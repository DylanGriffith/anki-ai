class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :stamp_service_worker_user

  helper_method :current_user

  private

  def current_user
    @current_user ||= session[:user_id] ? User.find_by(id: session[:user_id]) : nil
  end

  def require_login
    return if current_user
    if request.format.json?
      head :unauthorized
    else
      redirect_to login_path, alert: "Please sign in first."
    end
  end

  # Identifies the authenticated user to the service worker so it can keep
  # per-user offline page caches on shared browsers (see public/service-worker.js).
  def stamp_service_worker_user
    response.headers["X-Anki-User-Id"] = current_user&.id.to_s
  end
end
