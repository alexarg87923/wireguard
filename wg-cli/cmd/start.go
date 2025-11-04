package cmd

import (
	"github.com/spf13/cobra"
	"wg-cli/internal/config"
	"wg-cli/internal/executor"
)

var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Start the WireGuard container",
	Long:  `Starts the WireGuard VPN container with the configured settings.`,
	RunE:  runStart,
}

func init() {
	rootCmd.AddCommand(startCmd)
}

func runStart(cmd *cobra.Command, args []string) error {
	if err := config.Load(); err != nil {
		return err
	}

	exec := executor.New(log)
	if err := exec.Execute("start"); err != nil {
		return err
	}

	profile := config.Get("PROFILE", "")
	if profile == "client" {
		log.Info("Setting up host routing rules...")
		if err := exec.Execute("setup_routing"); err != nil {
			return err
		}
	}

	return nil
}