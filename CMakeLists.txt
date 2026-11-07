cmake_minimum_required(VERSION 3.20)
project(SAViewer LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ---------------------------------------------------------------- 核心库（跨平台）
add_library(sa_core STATIC
  src/assets.cpp
  src/dff.cpp
  src/store.cpp
  src/renderer.cpp
)
target_include_directories(sa_core PUBLIC src)

option(SA_BUILD_IOS "Build the iOS viewer app" OFF)

if(SA_BUILD_IOS)
  set(APP_NAME SAViewer)

  add_executable(${APP_NAME}
    src/main_ios.mm
    src/metal_backend.mm
    shaders/ModelRenderer.metal
  )
  target_link_libraries(${APP_NAME} PRIVATE sa_core)

  set_target_properties(${APP_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.minke4.saviewer"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "16.0"
    XCODE_ATTRIBUTE_ENABLE_BITCODE NO
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES
  )

  # Metal 源码需要在编译阶段用 xcrun 预编译成 .metallib
  find_program(XCRUN xcrun)
  if(XCRUN)
    set(METALLIB "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")
    set(METAL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/shaders/ModelRenderer.metal")
    add_custom_command(
      OUTPUT ${METALLIB}
      COMMAND ${XCRUN} -sdk iphoneos metal -c ${METAL_SRC} -o ${CMAKE_CURRENT_BINARY_DIR}/ModelRenderer.air
      COMMAND ${XCRUN} -sdk iphoneos metallib ${CMAKE_CURRENT_BINARY_DIR}/ModelRenderer.air -o ${METALLIB}
      DEPENDS ${METAL_SRC}
      COMMENT "编译 Metal 着色器 → default.metallib"
    )
    add_custom_target(sa_metallib ALL DEPENDS ${METALLIB})
    add_dependencies(${APP_NAME} sa_metallib)
    # 把 metallib 放进 app 包根目录（newDefaultLibrary 会自动查找）
    set_target_properties(${APP_NAME} PROPERTIES
      MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    )
    add_custom_command(TARGET ${APP_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              ${METALLIB} "$<TARGET_BUNDLE_DIR:${APP_NAME}>/default.metallib"
      COMMENT "复制 default.metallib 到 app 包"
    )
  endif()

  target_link_libraries(${APP_NAME} PRIVATE
    "-framework Metal"
    "-framework MetalKit"
    "-framework UIKit"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework CoreGraphics"
  )
endif()
