desc "Create a user with a username and password"
task "user:create", [ :name, :password ] => :environment do |_task, args|
  name = args[:name] || ENV["NAME"]
  password = args[:password] || ENV["PASSWORD"]
  abort "Usage: bin/rails \"user:create[name,password]\"" if name.blank? || password.blank?

  user = User.new(name: name, password: password)
  if user.save
    puts "Created user #{user.name.inspect} (id: #{user.id})"
  else
    abort "Failed: #{user.errors.full_messages.to_sentence}"
  end
end
