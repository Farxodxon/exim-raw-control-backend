# Use Dart SDK image
FROM dart:3.2-sdk

# Set working directory
WORKDIR /app

# Copy pubspec and get dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy source code
COPY . .

# Expose port
EXPOSE 8080

# Run with JIT (no compilation needed)
CMD ["dart", "run", "lib/server.dart"]
