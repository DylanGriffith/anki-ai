class AddLastModelToAiSettings < ActiveRecord::Migration[8.1]
  def change
    # The model id chosen on the last "New AI Deck" creation — remembered
    # globally (app-wide, not per user) to preselect the form next time.
    add_column :ai_settings, :last_model, :string
  end
end
