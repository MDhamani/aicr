// Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package bundler

import (
	"context"
	"testing"

	"gopkg.in/yaml.v3"

	"github.com/NVIDIA/aicr/pkg/bundler/config"
	"github.com/NVIDIA/aicr/pkg/defaults"
	"github.com/NVIDIA/aicr/pkg/recipe"
)

func TestInjectDRAEvictionLabel(t *testing.T) {
	tests := []struct {
		name       string
		draName    string
		gpuName    string
		configured config.NodeLabel
		wantKey    string
		wantValue  string
	}{
		{
			name:      "standard components use default",
			draName:   draComponentName,
			gpuName:   gpuOperatorComponentName,
			wantKey:   defaults.DRAEvictionNodeLabelKey,
			wantValue: defaults.DRAEvictionNodeLabelValue,
		},
		{
			name:       "standard components use configured label",
			draName:    draComponentName,
			gpuName:    gpuOperatorComponentName,
			configured: config.NodeLabel{Key: "example.com/dra-ready", Value: "enabled"},
			wantKey:    "example.com/dra-ready",
			wantValue:  "enabled",
		},
		{
			name:      "OpenShift components use default",
			draName:   "nvidia-dra-driver-gpu-ocp",
			gpuName:   "gpu-operator-ocp",
			wantKey:   defaults.DRAEvictionNodeLabelKey,
			wantValue: defaults.DRAEvictionNodeLabelValue,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opts := []config.Option{}
			if tt.configured != (config.NodeLabel{}) {
				opts = append(opts, config.WithDRAEvictionNodeLabel(tt.configured))
			}
			b, err := New(WithConfig(config.NewConfig(opts...)))
			if err != nil {
				t.Fatalf("New() error = %v", err)
			}

			nodeSelector := map[string]any{
				"node.dgxc.nvidia.com/has-gpu": "true",
				tt.wantKey:                     "stale",
			}
			if tt.configured != (config.NodeLabel{}) {
				nodeSelector[defaults.DRAEvictionNodeLabelKey] = "stale-default"
			}
			values := map[string]map[string]any{
				tt.draName: {
					"kubeletPlugin": map[string]any{
						"nodeSelector": nodeSelector,
					},
				},
				tt.gpuName: {
					"driver": map[string]any{
						"manager": map[string]any{
							"env": []any{
								map[string]any{"name": "UNRELATED", "value": "preserved"},
								map[string]any{
									"name":      draEvictionEnvName,
									"valueFrom": map[string]any{"fieldRef": map[string]any{"fieldPath": "metadata.name"}},
								},
								map[string]any{"name": draEvictionEnvName, "value": "duplicate"},
							},
						},
					},
				},
			}
			rr := &recipe.RecipeResult{ComponentRefs: []recipe.ComponentRef{
				{Name: tt.gpuName},
				{Name: tt.draName},
			}}

			b.injectDRAEvictionLabel(values, rr)

			if got := dig(values[tt.draName], "kubeletPlugin", "nodeSelector", tt.wantKey); got != tt.wantValue {
				t.Errorf("DRA node selector = %v, want %q", got, tt.wantValue)
			}
			if got := dig(values[tt.draName], "kubeletPlugin", "nodeSelector", "node.dgxc.nvidia.com/has-gpu"); got != "true" {
				t.Errorf("existing accelerated selector = %v, want preserved", got)
			}
			if tt.configured != (config.NodeLabel{}) {
				if got := dig(values[tt.draName], "kubeletPlugin", "nodeSelector", defaults.DRAEvictionNodeLabelKey); got != nil {
					t.Errorf("default DRA selector survived custom-label replacement: %v", got)
				}
			}
			if got := driverManagerEnvValues(values[tt.gpuName], draEvictionEnvName); len(got) != 1 || got[0] != tt.wantKey {
				t.Errorf("Driver Manager eviction env values = %v, want [%s]", got, tt.wantKey)
			}
			if got := driverManagerEnvValues(values[tt.gpuName], "UNRELATED"); len(got) != 1 || got[0] != "preserved" {
				t.Errorf("unrelated Driver Manager env values = %v, want [preserved]", got)
			}
		})
	}
}

func TestInjectDRAEvictionLabel_RequiresBothComponents(t *testing.T) {
	tests := []struct {
		name   string
		values map[string]map[string]any
		refs   []recipe.ComponentRef
	}{
		{
			name:   "DRA absent",
			values: map[string]map[string]any{gpuOperatorComponentName: {}},
			refs:   []recipe.ComponentRef{{Name: gpuOperatorComponentName}},
		},
		{
			name:   "GPU Operator absent",
			values: map[string]map[string]any{draComponentName: {}},
			refs:   []recipe.ComponentRef{{Name: draComponentName}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b, err := New()
			if err != nil {
				t.Fatalf("New() error = %v", err)
			}
			b.injectDRAEvictionLabel(tt.values, &recipe.RecipeResult{ComponentRefs: tt.refs})
			for name, values := range tt.values {
				if len(values) != 0 {
					t.Errorf("component %s values changed with only one contract half enabled: %v", name, values)
				}
			}
		})
	}
}

func TestMake_DRAEvictionLabelMergesSchedulingSelector(t *testing.T) {
	b, err := New(WithConfig(config.NewConfig(
		config.WithAcceleratedNodeSelector(map[string]string{
			"node.dgxc.nvidia.com/has-gpu": "true",
		}),
	)))
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	rr := &recipe.RecipeResult{
		APIVersion: "aicr.run/v1alpha2",
		Kind:       "Recipe",
		Criteria: &recipe.Criteria{
			Service:     "eks",
			Accelerator: "h100",
			Intent:      "training",
		},
		ComponentRefs: []recipe.ComponentRef{
			{
				Name:    gpuOperatorComponentName,
				Version: "v26.4.0",
				Type:    recipe.ComponentTypeHelm,
				Source:  "https://helm.ngc.nvidia.com/nvidia",
			},
			{
				Name:    draComponentName,
				Version: "25.12.0",
				Type:    recipe.ComponentTypeHelm,
				Source:  "https://helm.ngc.nvidia.com/nvidia",
				Overrides: map[string]any{
					"nvidiaDriverRoot": "/run/nvidia/driver",
				},
			},
		},
		DeploymentOrder: []string{gpuOperatorComponentName, draComponentName},
	}

	outputDir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), draBundleMakeTimeout)
	defer cancel()
	if _, err := b.Make(ctx, rr, outputDir); err != nil {
		t.Fatalf("Make() error = %v", err)
	}

	var draValues map[string]any
	if err := yaml.Unmarshal(readBundleValues(t, outputDir, "002-nvidia-dra-driver-gpu/values.yaml"), &draValues); err != nil {
		t.Fatalf("decode DRA values: %v", err)
	}
	if got := dig(draValues, "kubeletPlugin", "nodeSelector", "node.dgxc.nvidia.com/has-gpu"); got != "true" {
		t.Errorf("accelerated node selector = %v, want true", got)
	}
	if got := dig(draValues, "kubeletPlugin", "nodeSelector", defaults.DRAEvictionNodeLabelKey); got != defaults.DRAEvictionNodeLabelValue {
		t.Errorf("DRA eviction node selector = %v, want %s", got, defaults.DRAEvictionNodeLabelValue)
	}

	var gpuValues map[string]any
	if err := yaml.Unmarshal(readBundleValues(t, outputDir, "001-gpu-operator/values.yaml"), &gpuValues); err != nil {
		t.Fatalf("decode GPU Operator values: %v", err)
	}
	if got := driverManagerEnvValues(gpuValues, draEvictionEnvName); len(got) != 1 || got[0] != defaults.DRAEvictionNodeLabelKey {
		t.Errorf("Driver Manager eviction env values = %v, want [%s]", got, defaults.DRAEvictionNodeLabelKey)
	}
}

func driverManagerEnvValues(values map[string]any, name string) []string {
	env, _ := dig(values, "driver", "manager", "env").([]any)
	result := make([]string, 0, 1)
	for _, entry := range env {
		envMap, ok := entry.(map[string]any)
		if !ok || envMap["name"] != name {
			continue
		}
		if value, ok := envMap["value"].(string); ok {
			result = append(result, value)
		}
	}
	return result
}
