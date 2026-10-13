// Runs the upstream Mozhi web server (codeberg.org/aryak/mozhi) for
// contract-testing the Flutter client. Host/port come from argv or default
// to 127.0.0.1:3123.
package main

import (
	"os"

	"codeberg.org/aryak/mozhi/serve"
)

func main() {
	host, port := "127.0.0.1", "3123"
	if len(os.Args) > 1 {
		host = os.Args[1]
	}
	if len(os.Args) > 2 {
		port = os.Args[2]
	}
	serve.Serve(host, port)
}
