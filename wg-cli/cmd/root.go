package cmd

import (
    "github.com/spf13/cobra"
    "wg-cli/pkg/logger"
)

var (
    verbose bool
    log     *logger.Logger

    rootCmd = &cobra.Command{
        Use:   "wg",
        Short: "WireGuard service manager",
        Long:  `A CLI tool to manage WireGuard VPN containers and configurations.`,
        PersistentPreRun: func(cmd *cobra.Command, args []string) {
            log = logger.New(verbose)
        },
    }
)

func init() {
    rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "verbose output")
}

func Execute() error {
    return rootCmd.Execute()
}