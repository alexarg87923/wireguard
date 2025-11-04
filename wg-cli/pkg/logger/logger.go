package logger

import (
    "fmt"
    "github.com/fatih/color"
)

type Logger struct {
    verbose bool
}

func New(verbose bool) *Logger {
    return &Logger{verbose: verbose}
}

func (l *Logger) Info(format string, args ...interface{}) {
    color.Blue("i " + fmt.Sprintf(format, args...))
}

func (l *Logger) Success(format string, args ...interface{}) {
    color.Green("✓ " + fmt.Sprintf(format, args...))
}

func (l *Logger) Warning(format string, args ...interface{}) {
    color.Yellow("⚠ " + fmt.Sprintf(format, args...))
}

func (l *Logger) Error(format string, args ...interface{}) {
    color.Red("✗ " + fmt.Sprintf(format, args...))
}

func (l *Logger) Debug(format string, args ...interface{}) {
    if l.verbose {
        color.White("🔍 " + fmt.Sprintf(format, args...))
    }
}