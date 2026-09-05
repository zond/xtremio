#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint xtremio_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'xtremio_core'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # `-force_load` below pulls in every object in the Rust static library,
  # including the ones nothing calls, so this pod links against whatever the
  # whole crate graph refers to rather than whatever the app reaches. Two
  # system frameworks are only ever named from there, and without them the
  # pod fails to link with "symbol(s) not found":
  #
  #   SystemConfiguration  the `system_configuration` crate, which hyper-util
  #                        uses to read the system proxy settings for reqwest
  #                        (_SCDynamicStoreCopyProxies, _kSCPropNetProxies*)
  #   OpenDirectory        `sysinfo`'s user enumeration, reached through the
  #                        streaming server (_ODQueryCreateWithNode, _kOD*)
  #
  # Cargo cannot declare these: they belong to a transitive dependency, and
  # its own `#[link]` attributes are not what Xcode links the pod with.
  s.frameworks = 'SystemConfiguration', 'OpenDirectory'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust xtremio_core',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/libxtremio_core.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libxtremio_core.a',
  }
end