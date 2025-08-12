FROM ruby:3.2.2

WORKDIR /app
COPY . .

RUN gem install bundler && bundle install

CMD ["ruby", "pugbot.rb"]
