# tvOS is configured with CMake's native Apple platform support. The iOS
# toolchain historically supplied this helper late in libultraship's configure.
function(set_xcode_property target property value variants)
  set_target_properties(${target} PROPERTIES XCODE_ATTRIBUTE_${property} "${value}")
endfunction()
