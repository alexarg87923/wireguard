package scripts

import (
    _ "embed"
    "fmt"
)

type ScriptManager struct {
    scripts map[string]string
}

var (
    //go:embed scripts/start_container.sh
    startScript string
    
    //go:embed scripts/stop_container.sh
    stopScript string
    
    //go:embed scripts/reset_container.sh
    resetScript string
    
    //go:embed scripts/gen_psk.sh
    genPskScript string
    
    //go:embed scripts/gen_keys.sh
    genKeysScript string
    
    //go:embed scripts/setup_host_routing.sh
    setupRoutingScript string
    
    //go:embed scripts/remove_host_routing.sh
    removeRoutingScript string
)

func New() *ScriptManager {
    return &ScriptManager{
        scripts: map[string]string{
            "start":           startScript,
            "stop":            stopScript,
            "reset":           resetScript,
            "gen_psk":         genPskScript,
            "gen_keys":        genKeysScript,
            "setup_routing":   setupRoutingScript,
            "remove_routing":  removeRoutingScript,
        },
    }
}

func (sm *ScriptManager) Get(name string) (string, error) {
    script, ok := sm.scripts[name]
    if !ok {
        return "", fmt.Errorf("script not found: %s", name)
    }
    return script, nil
}

func (sm *ScriptManager) List() []string {
    names := make([]string, 0, len(sm.scripts))
    for name := range sm.scripts {
        names = append(names, name)
    }
    return names
}