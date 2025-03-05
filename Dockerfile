FROM ruby:3.1

# Set the working directory
WORKDIR /usr/src/app

# Copy the Gemfile and install dependencies
COPY Gemfile ./
RUN bundle install

# Copy the rest of the application code
COPY . .

# Expose the port the app runs on
EXPOSE 4000

# Command to run the Jekyll server
CMD ["jekyll", "serve", "--host", "0.0.0.0"]
