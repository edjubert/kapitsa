# Writes SRC (the chat page) into OUT as a C++ string literal: ni::<NAME>.
file(READ ${SRC} BODY)
if(DEFINED BRAND)
  # Use the canonical SVG masters as data URLs: the page stays self-contained
  # and its existing img-src data: CSP needs no additional network permission.
  foreach(ASSET kapitsa-icon kapitsa-logo-light kapitsa-logo-dark kapitsa-mark kapitsa-mark-light)
    file(READ "${BRAND}/${ASSET}.svg" SVG HEX)
    string(REGEX REPLACE "([0-9a-fA-F][0-9a-fA-F])" "%\\1" ENCODED "${SVG}")
    string(REPLACE "__${ASSET}__" "data:image/svg+xml,${ENCODED}" BODY "${BODY}")
  endforeach()
endif()
file(WRITE ${OUT} "// generated from ${SRC}\nnamespace ni { extern const char* const ${NAME}; const char* const ${NAME} = R\"KAPITSAEMBED(${BODY})KAPITSAEMBED\"; }\n")
