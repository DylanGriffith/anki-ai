# POST /sync — drains the client's offline outbox. Applies a batch of ops
# idempotently (see Syncing::ApplyOps) and reports a per-op status so the
# client can drop everything the server has definitively handled.
class SyncController < ApplicationController
  before_action :require_login

  def create
    results = Syncing::ApplyOps.call(user: current_user, ops: parsed_ops)
    summary = results.group_by(&:status).transform_values(&:count)
    render json: {
      results: results.map { |r| { op_id: r.op_id, status: r.status, error: r.error }.compact },
      applied: summary["applied"].to_i,
      duplicates: summary["duplicate"].to_i,
      invalid: summary["invalid"].to_i
    }
  rescue JSON::ParserError
    render json: { error: "invalid JSON body" }, status: :bad_request
  rescue ActionController::ParameterMissing
    render json: { error: "missing ops" }, status: :bad_request
  end

  private

  def parsed_ops
    body = request.raw_post
    parsed = body.present? ? JSON.parse(body) : {}
    raise ActionController::ParameterMissing, :ops unless parsed.is_a?(Hash) && parsed.key?("ops")
    parsed["ops"]
  end
end
