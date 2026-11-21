class SessionsController < ApplicationController
  def new
    redirect_to root_path if current_user
  end

  def create
    if (user = User.authenticate(params[:name].to_s, params[:password].to_s))
      reset_session
      session[:user_id] = user.id
      redirect_to root_path, notice: "Signed in as #{user.name}."
    else
      flash.now[:alert] = "Invalid name or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end
end
