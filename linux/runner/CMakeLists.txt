cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Hardening: link the runner as a position-independent executable so the OS can
# load it at a random address (ASLR). The Flutter template leaves this off, and
# the packaged binary is then reported by lintian as hardening-no-pie — which
# the release workflow treats as a failure (#300). The plugin libraries are
# shared objects and already position-independent; only this executable needs
# the flags, so they are set on the target rather than globally.
target_compile_options(${BINARY_NAME} PRIVATE "-fPIE")
target_link_options(${BINARY_NAME} PRIVATE "-pie")

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
