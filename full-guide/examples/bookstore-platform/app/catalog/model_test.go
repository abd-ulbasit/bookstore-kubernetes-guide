package main

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestBookValidate(t *testing.T) {
	tests := []struct {
		name       string
		in         Book
		wantErr    error
		wantTitle  string // expected normalised title
		wantISBN   string // expected normalised ISBN
		wantAuthor string
	}{
		{
			name:       "happy ISBN-13",
			in:         Book{Title: "T", Author: "A", ISBN: "978-1617293726"},
			wantTitle:  "T",
			wantISBN:   "9781617293726",
			wantAuthor: "A",
		},
		{
			name:       "ISBN-10 with X check digit, uppercase + hyphen-strip",
			in:         Book{Title: "T", Author: "A", ISBN: "0-306-40615-x"},
			wantTitle:  "T",
			wantISBN:   "030640615X",
			wantAuthor: "A",
		},
		{
			name:       "whitespace title is trimmed",
			in:         Book{Title: "   T   ", Author: "   A   ", ISBN: "9781617293726"},
			wantTitle:  "T",
			wantISBN:   "9781617293726",
			wantAuthor: "A",
		},
		{name: "missing title", in: Book{Author: "A", ISBN: "9781617293726"}, wantErr: ErrInvalid},
		{name: "missing author", in: Book{Title: "T", ISBN: "9781617293726"}, wantErr: ErrInvalid},
		{name: "ISBN too short", in: Book{Title: "T", Author: "A", ISBN: "12345"}, wantErr: ErrInvalid},
		{name: "ISBN non-digit", in: Book{Title: "T", Author: "A", ISBN: "abcdefghijklm"}, wantErr: ErrInvalid},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			b := tc.in
			err := b.Validate()
			if tc.wantErr != nil {
				assert.True(t, errors.Is(err, tc.wantErr))
				return
			}
			assert.NoError(t, err)
			assert.Equal(t, tc.wantTitle, b.Title)
			assert.Equal(t, tc.wantAuthor, b.Author)
			assert.Equal(t, tc.wantISBN, b.ISBN)
		})
	}
}

func BenchmarkBookValidate(b *testing.B) {
	bk := Book{Title: "The Go Programming Language", Author: "Donovan", ISBN: "978-0134190440"}
	b.ResetTimer()
	for range b.N {
		clone := bk
		_ = clone.Validate()
	}
}
