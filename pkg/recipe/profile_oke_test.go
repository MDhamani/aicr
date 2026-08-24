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

package recipe

import (
	"testing"

	"github.com/NVIDIA/aicr/pkg/allocpolicy"
)

func okeCriteria() *Criteria {
	return &Criteria{
		Service:     CriteriaServiceOKE,
		Accelerator: CriteriaAcceleratorL40S,
		OS:          CriteriaOSOracleLinux,
		Intent:      CriteriaIntentTraining,
	}
}

// TestOKEGpuStackProfileResolution pins the OKE family conversion: the
// oke-ol overlay declares gpuStack with default oci-default (the stock OKE
// cluster — Oracle image driver + OKE's auto-installed device plugin as the
// external advertiser) and alternatives operator-plugin (image driver, GPU
// Operator's plugin) and operator-managed (bring-your-own driverless image;
// the operator installs driver, toolkit, and plugin, and the DRA root moves
// in lockstep). Every value's DD-style distinguisher is readiness-scoped
// (deployed ClusterPolicy state), so this also pins the readiness routing.
func TestOKEGpuStackProfileResolution(t *testing.T) {
	t.Parallel()

	type wantReadiness struct {
		driverEnabled string
		pluginEnabled string
	}
	tests := []struct {
		name           string
		selection      string
		wantValue      string
		wantAdvertiser string
		wantDriver     bool
		wantToolkit    bool
		wantPlugin     bool
		wantDRARoot    string
		wantAssume     bool
		wantReadiness  wantReadiness
	}{
		{
			name:           "default selection is oci-default with the external advertiser",
			selection:      "",
			wantValue:      "oci-default",
			wantAdvertiser: allocpolicy.AdvertiserExternal,
			wantDriver:     false,
			wantToolkit:    false,
			wantPlugin:     false,
			wantDRARoot:    "/",
			wantAssume:     true,
			wantReadiness:  wantReadiness{driverEnabled: "false", pluginEnabled: "false"},
		},
		{
			name:           "operator-plugin keeps the image driver and advertises via the operator",
			selection:      "gpuStack=operator-plugin",
			wantValue:      "operator-plugin",
			wantAdvertiser: "",
			wantDriver:     false,
			wantToolkit:    false,
			wantPlugin:     true,
			wantDRARoot:    "/",
			wantAssume:     true,
			wantReadiness:  wantReadiness{driverEnabled: "false", pluginEnabled: "true"},
		},
		{
			name:           "operator-managed owns driver, toolkit, plugin, and the DRA root",
			selection:      "gpuStack=operator-managed",
			wantValue:      "operator-managed",
			wantAdvertiser: "",
			wantDriver:     true,
			wantToolkit:    true,
			wantPlugin:     true,
			wantDRARoot:    "/run/nvidia/driver",
			wantAssume:     false,
			wantReadiness:  wantReadiness{driverEnabled: "true", pluginEnabled: "true"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result, err := NewBuilder().BuildFromCriteriaWithProfile(
				t.Context(), okeCriteria(), tt.selection)
			if err != nil {
				t.Fatalf("BuildFromCriteriaWithProfile() failed: %v", err)
			}
			selected := result.Metadata.SelectedProfile
			if selected == nil {
				t.Fatal("metadata.selectedProfile is nil")
				return
			}
			if selected.Name != "gpuStack" || selected.Value != tt.wantValue {
				t.Errorf("selectedProfile = %s=%s, want gpuStack=%s", selected.Name, selected.Value, tt.wantValue)
			}
			if selected.Advertiser != tt.wantAdvertiser {
				t.Errorf("advertiser = %q, want %q", selected.Advertiser, tt.wantAdvertiser)
			}
			if result.APIVersion != RecipeProfileAPIVersion {
				t.Errorf("apiVersion = %q, want %q", result.APIVersion, RecipeProfileAPIVersion)
			}

			// Declaration-wide ownedPaths: identical for every selection.
			wantOwned := map[string][]string{
				"gpu-operator": {
					"devicePlugin.enabled", "driver.enabled",
					"driver.useOpenKernelModules", "enabled",
					"hostPaths.driverInstallDir", "toolkit.enabled",
				},
				"nvidia-dra-driver-gpu": {"enabled", "nvidiaDriverRoot"},
				"nvsentinel":            {"enabled", "labeler.assumeDriverInstalled"},
			}
			for component, want := range wantOwned {
				got := selected.OwnedPaths[component]
				if len(got) != len(want) {
					t.Errorf("ownedPaths[%s] = %v, want %v", component, got, want)
					continue
				}
				for i := range want {
					if got[i] != want[i] {
						t.Errorf("ownedPaths[%s] = %v, want %v", component, got, want)
						break
					}
				}
			}

			gpuValues, err := result.GetValuesForComponentWithContext(t.Context(), "gpu-operator")
			if err != nil {
				t.Fatalf("GetValuesForComponentWithContext(gpu-operator): %v", err)
			}
			if v, ok := nestedBool(gpuValues, "driver", "enabled"); !ok || v != tt.wantDriver {
				t.Errorf("driver.enabled = %v (set: %v), want %v", v, ok, tt.wantDriver)
			}
			if v, ok := nestedBool(gpuValues, "toolkit", "enabled"); !ok || v != tt.wantToolkit {
				t.Errorf("toolkit.enabled = %v (set: %v), want %v", v, ok, tt.wantToolkit)
			}
			if v, ok := nestedBool(gpuValues, "devicePlugin", "enabled"); !ok || v != tt.wantPlugin {
				t.Errorf("devicePlugin.enabled = %v (set: %v), want %v", v, ok, tt.wantPlugin)
			}

			draValues, err := result.GetValuesForComponentWithContext(t.Context(), "nvidia-dra-driver-gpu")
			if err != nil {
				t.Fatalf("GetValuesForComponentWithContext(nvidia-dra-driver-gpu): %v", err)
			}
			if root, _ := draValues["nvidiaDriverRoot"].(string); root != tt.wantDRARoot {
				t.Errorf("nvidiaDriverRoot = %q, want %q", root, tt.wantDRARoot)
			}

			nvsValues, err := result.GetValuesForComponentWithContext(t.Context(), nvsentinelComponent)
			if err != nil {
				t.Fatalf("GetValuesForComponentWithContext(nvsentinel): %v", err)
			}
			if v, ok := nestedBool(nvsValues, "labeler", "assumeDriverInstalled"); !ok || v != tt.wantAssume {
				t.Errorf("assumeDriverInstalled = %v (set: %v), want %v", v, ok, tt.wantAssume)
			}

			// Readiness distinguishers: deployed ClusterPolicy state, routed
			// into validation.readiness — never spec.constraints.
			readiness := map[string]string{}
			if result.Validation != nil && result.Validation.Readiness != nil {
				for _, c := range result.Validation.Readiness.Constraints {
					readiness[c.Name] = c.Value
				}
			}
			if got := readiness["K8s.policy.driver.enabled"]; got != tt.wantReadiness.driverEnabled {
				t.Errorf("readiness K8s.policy.driver.enabled = %q, want %q", got, tt.wantReadiness.driverEnabled)
			}
			if got := readiness["K8s.policy.devicePlugin.enabled"]; got != tt.wantReadiness.pluginEnabled {
				t.Errorf("readiness K8s.policy.devicePlugin.enabled = %q, want %q", got, tt.wantReadiness.pluginEnabled)
			}
			for _, c := range result.Constraints {
				if c.Name == "K8s.policy.driver.enabled" || c.Name == "K8s.policy.devicePlugin.enabled" {
					t.Errorf("readiness distinguisher %q leaked into spec.constraints", c.Name)
				}
			}
		})
	}
}
