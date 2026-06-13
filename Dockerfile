# Use Dart SDK image
FROM dart:3.2-sdk AS build

# Set working directory
WORKDIR /app

# Copy pubspec files
COPY pubspec.* ./

# Get dependencies
RUN dart pub get

# Copy source code
COPY . .

# Compile to native executable
RUN dart compile exe lib/server.dart -o bin/server

# Build runtime image
FROM debian:bullseye-slim

# Install CA certificates for SSL
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy compiled binary
COPY --from=build /app/bin/server .

# Expose port
EXPOSE 8080

# Run the server
CMD ["./server"]
