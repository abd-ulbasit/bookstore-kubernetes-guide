package main

import (
	"errors"
	"regexp"
	"strings"
)

// Book is the domain model the service exposes via HTTP and persists to the
// catalog database. ISBN is stored without separators (digits + final X).
type Book struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Author string `json:"author"`
	ISBN   string `json:"isbn"`
}

// ErrNotFound is returned by Repository.Get when no book has the given ID.
// Wrap or check via errors.Is — keeps callers from importing pgx error types.
var ErrNotFound = errors.New("book not found")

// ErrInvalid is returned by Repository.Create / Update when the input fails
// model-level validation.
var ErrInvalid = errors.New("invalid book")

// isbnRE accepts 10- or 13-character ISBNs after separators are stripped.
// Last char of ISBN-10 may be 'X'; everything else is a digit.
var isbnRE = regexp.MustCompile(`^([0-9]{9}[0-9Xx]|[0-9]{13})$`)

// Validate returns ErrInvalid wrapped with a per-field reason when the
// receiver isn't a well-formed Book. Performs in-place normalisation of
// the ISBN (strips hyphens + spaces, uppercases the X check digit).
func (b *Book) Validate() error {
	b.Title = strings.TrimSpace(b.Title)
	b.Author = strings.TrimSpace(b.Author)
	b.ISBN = strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(b.ISBN))

	if b.Title == "" {
		return errors.Join(ErrInvalid, errors.New("title is required"))
	}
	if b.Author == "" {
		return errors.Join(ErrInvalid, errors.New("author is required"))
	}
	if !isbnRE.MatchString(b.ISBN) {
		return errors.Join(ErrInvalid, errors.New("isbn must be 10 or 13 characters (digits, with optional 'X' check digit for ISBN-10)"))
	}
	return nil
}
