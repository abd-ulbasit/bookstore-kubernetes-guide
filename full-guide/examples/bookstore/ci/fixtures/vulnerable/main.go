// Package main is a scanner fixture. It is deliberately broken and must never
// be deployed outside the pipeline's own tests. Each flaw below is planted so a
// scanner has something it must report; see README.md for the list.
package main

import (
	"crypto/md5" // gosec G401, G501: a weak hash
	"database/sql"
	"fmt"
	"net/http"
	"os/exec"

	"golang.org/x/text/language" // v0.3.6: GO-2021-0113 is reachable below
)

var db *sql.DB

func main() {
	http.HandleFunc("/books", func(w http.ResponseWriter, r *http.Request) {
		// Reachable call into the vulnerable x/text version (govulncheck).
		tags, _, _ := language.ParseAcceptLanguage(r.Header.Get("Accept-Language"))

		// String-built SQL (gosec G202, the Semgrep rule bookstore-sql-string-concat).
		if db != nil {
			rows, err := db.Query("SELECT title FROM books WHERE lang = '" + fmt.Sprint(tags) + "'")
			if err == nil {
				defer rows.Close()
			}
		}

		// A request value reaches a shell (gosec G204).
		out, _ := exec.Command("sh", "-c", r.URL.Query().Get("cmd")).Output()

		// A session cookie without HttpOnly, and an HTML page with none of the
		// headers a browser expects (ZAP baseline rule 10010).
		sum := md5.Sum(out)
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "fixture-not-a-real-session"})
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, "<html><body><h1>books</h1><p>%x</p></body></html>\n", sum)
	})
	// No timeouts (gosec G114).
	http.ListenAndServe(":8080", nil)
}
