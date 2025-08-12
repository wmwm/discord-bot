FROM ruby:3.2.2

# Install dependencies required for building native gems
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential

WORKDIR /app
COPY . .

# Precompile gems to speed up installation and reduce image size
RUN gem install bundler -v "$(grep -A 1 "BUNDLED WITH" Gemfile.lock | tail -n 1)"
RUN gem install bundler && bundle install

# Remove development dependencies
RUN bundle clean --force
RUN bundle install --without development test --force

# Create a writable directory for the database
RUN mkdir -p /app/data && chown nobody /app/data

# Set user to run the application (non-root user)
USER nobody

CMD ["ruby", "pugbot.rb"]
