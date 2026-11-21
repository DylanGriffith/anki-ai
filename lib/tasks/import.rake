desc "Import an Anki .apkg into a user's account"
task "import:apkg", [ :path, :user, :name ] => :environment do |_task, args|
  path = args[:path] || ENV["PATH_"]
  user_name = args[:user] || ENV["USER_NAME"]
  abort "Usage: bin/rails \"import:apkg[path,username,optional_deck_name]\"" if path.blank? || user_name.blank?

  user = User.find_by!(name: user_name)
  name = args[:name].presence
  start = Time.current
  deck = Decks::Import.call(user, path, name: name)
  puts "Imported “#{deck.name}” for #{user.name}: " \
       "#{deck.cards.count} cards, #{deck.notes.count} notes, " \
       "#{deck.note_types.count} note types, #{deck.media_files.count} media files " \
       "(#{(Time.current - start).round(1)}s)"
end
