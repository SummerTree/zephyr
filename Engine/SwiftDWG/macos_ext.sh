# Set environment variables (replace paths with your actual macOS paths)
export DWG_INCLUDE="/Users/josephmontanez/Documents/dev/libredwg/build/include"
export DWG_LIB="/Users/josephmontanez/Documents/dev/libredwg/build/lib"
export DWG_SRC="/Users/josephmontanez/Documents/dev/libredwg/src"

# Run the swift build command
swift build -c release -vv -Xcc "-I${DWG_INCLUDE}"
