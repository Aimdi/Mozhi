// Appended to Emscripten's glue (--post-js), inside the module: what
// web/bergamot/worker.js needs to pass strings and model bytes to the C API.
// HEAPU8 is replaced when the memory grows, so it is read through a function.
Module['mozhi'] = {
  heap: function () {
    return HEAPU8;
  },
  utf8ToString: UTF8ToString,
  stringToUTF8: stringToUTF8,
  lengthBytesUTF8: lengthBytesUTF8,
};
