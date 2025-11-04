package executor

import (
    "fmt"
    "io/ioutil"
    "os"
    "os/exec"
    
    "wg-cli/internal/scripts"
    "wg-cli/pkg/logger"
)

// Executor handles script execution
type Executor struct {
    scriptManager *scripts.ScriptManager
    logger        *logger.Logger
}

// New creates a new Executor
func New(logger *logger.Logger) *Executor {
    return &Executor{
        scriptManager: scripts.New(),
        logger:        logger,
    }
}

func (e *Executor) Execute(scriptName string) error {
	return e.execute(scriptName, nil)
}

func (e *Executor) ExecuteWithEnv(scriptName string, envVars map[string]string) error {
	return e.execute(scriptName, envVars)
}

func (e *Executor) execute(scriptName string, envVars map[string]string) error {
	e.logger.Info("Executing %s...", scriptName)
	
	scriptContent, err := e.scriptManager.Get(scriptName)
	if err != nil {
		return fmt.Errorf("failed to get script: %w", err)
	}
	
	tmpFile, err := ioutil.TempFile("", fmt.Sprintf("wg-%s-*.sh", scriptName))
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	defer os.Remove(tmpFile.Name())
	
	if _, err := tmpFile.WriteString(scriptContent); err != nil {
		return fmt.Errorf("failed to write script: %w", err)
	}
	tmpFile.Close()
	
	if err := os.Chmod(tmpFile.Name(), 0755); err != nil {
		return fmt.Errorf("failed to set permissions: %w", err)
	}
	
	cmd := exec.Command("/bin/bash", tmpFile.Name())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	
	cmd.Env = os.Environ()
	if envVars != nil {
		for key, value := range envVars {
			cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", key, value))
		}
	}
	
	e.logger.Debug("Running: bash %s", tmpFile.Name())
	
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("script execution failed: %w", err)
	}
	
	e.logger.Success("Script completed successfully")
	return nil
}

// ExecuteWithArgs runs a script with additional arguments
func (e *Executor) ExecuteWithArgs(scriptName string, args ...string) error {
    // Similar to Execute but passes args to the script
    // Implementation here...
    return nil
}