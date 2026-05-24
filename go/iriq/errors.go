package iriq

import "errors"

var ErrParse = errors.New("iriq: parse error")

type ParseError struct{ Msg string }

func (e *ParseError) Error() string { return "iriq: parse error: " + e.Msg }

func (e *ParseError) Is(target error) bool { return target == ErrParse }

func newParseError(msg string) *ParseError { return &ParseError{Msg: msg} }
