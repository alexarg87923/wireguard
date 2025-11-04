package cmd

import (
    "github.com/spf13/cobra"
    "wg-cli/internal/executor"
)

var generateCmd = &cobra.Command{
    Use:   "generate",
    Short: "Generate WireGuard keys and PSKs",
    Long:  `Commands for generating WireGuard keys and pre-shared keys.`,
}

var genPskCmd = &cobra.Command{
    Use:   "psk",
    Short: "Generate a pre-shared key",
    RunE: func(cmd *cobra.Command, args []string) error {
        exec := executor.New(log)
        return exec.Execute("gen_psk")
    },
}

var genKeysCmd = &cobra.Command{
    Use:   "keys",
    Short: "Generate public/private key pair",
    RunE: func(cmd *cobra.Command, args []string) error {
        exec := executor.New(log)
        return exec.Execute("gen_keys")
    },
}

func init() {
    rootCmd.AddCommand(generateCmd)
    generateCmd.AddCommand(genPskCmd, genKeysCmd)
}