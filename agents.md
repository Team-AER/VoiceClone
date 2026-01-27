# VoiceClone AI Agent Workflows

This document defines specialized AI agent workflows for developing, testing, and maintaining the VoiceClone iOS application.

---

## Agent Types

### 1. Model Conversion Agent

**Purpose**: Convert and optimize Qwen3-TTS models for iOS deployment.

**Capabilities**:
- Execute Python scripts for ONNX/CoreML conversion
- Run quantization pipelines
- Validate model outputs
- Benchmark inference performance

**Workflow**:
```yaml
name: model-conversion
trigger: manual
steps:
  - name: setup-environment
    run: |
      cd scripts
      python3.12 -m venv .venv
      source .venv/bin/activate
      pip install -r requirements.txt

  - name: export-onnx
    run: |
      python export_onnx.py \
        --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
        --output ./onnx_models

  - name: convert-coreml
    run: |
      python convert_coreml.py \
        --onnx ./onnx_models/Qwen3-TTS-12Hz-1.7B-VoiceDesign.onnx \
        --output ./coreml_models/Qwen3TTS_VoiceDesign.mlpackage

  - name: quantize
    run: |
      python quantize_int4.py \
        --input ./coreml_models/Qwen3TTS_VoiceDesign.mlpackage \
        --output ./coreml_models/Qwen3TTS_VoiceDesign_INT4.mlpackage \
        --bits 4

  - name: validate
    run: |
      python validate_model.py \
        --model ./coreml_models/Qwen3TTS_VoiceDesign_INT4.mlpackage \
        --reference ./test_fixtures/reference_output.wav
```

**Commands**:
```bash
# Full conversion pipeline
/agent model-conversion run

# Single model conversion
/agent model-conversion convert --model VoiceDesign

# Validate existing model
/agent model-conversion validate --model ./path/to/model.mlpackage
```

---

### 2. iOS Build Agent

**Purpose**: Build, test, and archive the iOS application.

**Capabilities**:
- Compile Swift code
- Run unit and integration tests
- Generate code coverage reports
- Create release archives

**Workflow**:
```yaml
name: ios-build
trigger: [push, pull_request]
steps:
  - name: lint
    run: |
      swiftlint lint --strict

  - name: build-debug
    run: |
      xcodebuild build \
        -project VoiceClone.xcodeproj \
        -scheme VoiceClone \
        -configuration Debug \
        -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

  - name: test
    run: |
      xcodebuild test \
        -project VoiceClone.xcodeproj \
        -scheme VoiceClone \
        -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
        -resultBundlePath ./test-results.xcresult

  - name: coverage
    run: |
      xcrun xccov view --report ./test-results.xcresult --json > coverage.json
      python scripts/check_coverage.py --threshold 80

  - name: archive
    condition: branch == 'main'
    run: |
      xcodebuild archive \
        -project VoiceClone.xcodeproj \
        -scheme VoiceClone \
        -configuration Release \
        -archivePath ./build/VoiceClone.xcarchive
```

**Commands**:
```bash
# Build and test
/agent ios-build run

# Build only
/agent ios-build build

# Run tests with coverage
/agent ios-build test --coverage

# Create release archive
/agent ios-build archive
```

---

### 3. Code Generation Agent

**Purpose**: Generate boilerplate code, models, and SwiftUI views.

**Capabilities**:
- Generate Swift data models from JSON schemas
- Create SwiftUI view templates
- Generate Core Data entities
- Scaffold new features

**Templates**:

#### Feature Scaffold
```swift
// Template: feature
// Usage: /agent codegen feature --name VoiceEditor

// Features/{{name}}/Views/{{name}}View.swift
import SwiftUI

struct {{name}}View: View {
    @StateObject private var viewModel = {{name}}ViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("{{name}}")
        }
    }

    private var content: some View {
        // TODO: Implement view content
        Text("{{name}}")
    }
}

#Preview {
    {{name}}View()
}

// Features/{{name}}/ViewModels/{{name}}ViewModel.swift
import SwiftUI
import Combine

@MainActor
final class {{name}}ViewModel: ObservableObject {
    // TODO: Add state properties

    init() {
        // TODO: Initialize
    }
}
```

#### Model Generation
```swift
// Template: model
// Usage: /agent codegen model --schema voice.json

// Generated from JSON Schema
struct {{ModelName}}: Identifiable, Codable, Sendable {
    {{#properties}}
    let {{name}}: {{type}}
    {{/properties}}
}
```

**Commands**:
```bash
# Generate new feature
/agent codegen feature --name VoiceEditor

# Generate model from schema
/agent codegen model --schema schemas/voice.json --output Core/Models/

# Generate Core Data entity
/agent codegen entity --name VoiceEntity --attributes "id:UUID,name:String,createdAt:Date"
```

---

### 4. Performance Agent

**Purpose**: Profile and optimize application performance.

**Capabilities**:
- Run performance benchmarks
- Profile memory usage
- Analyze thermal impact
- Generate optimization reports

**Workflow**:
```yaml
name: performance
trigger: manual
steps:
  - name: build-profiling
    run: |
      xcodebuild build \
        -project VoiceClone.xcodeproj \
        -scheme VoiceClone \
        -configuration Release \
        -destination 'generic/platform=iOS'

  - name: benchmark-inference
    run: |
      xcrun simctl boot "iPhone 15 Pro"
      xcrun simctl install booted ./build/VoiceClone.app
      xcrun simctl launch --console booted com.voiceclone.app --benchmark

  - name: profile-memory
    run: |
      instruments -t "Allocations" \
        -D ./profiles/memory.trace \
        -w "iPhone 15 Pro" \
        ./build/VoiceClone.app

  - name: analyze-thermal
    run: |
      instruments -t "Energy Log" \
        -D ./profiles/thermal.trace \
        -w "iPhone 15 Pro" \
        ./build/VoiceClone.app

  - name: generate-report
    run: |
      python scripts/performance_report.py \
        --memory ./profiles/memory.trace \
        --thermal ./profiles/thermal.trace \
        --output ./reports/performance.md
```

**Metrics Tracked**:
| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| First Token Latency | <500ms | >800ms |
| Memory Peak | <3GB | >3.5GB |
| Inference Throughput | >50 tokens/s | <30 tokens/s |
| Battery per 10min | <5% | >8% |

**Commands**:
```bash
# Run full benchmark suite
/agent performance benchmark

# Profile memory only
/agent performance memory

# Generate report
/agent performance report
```

---

### 5. Documentation Agent

**Purpose**: Generate and maintain project documentation.

**Capabilities**:
- Generate API documentation from Swift code
- Update README and guides
- Create architecture diagrams
- Sync documentation with code changes

**Workflow**:
```yaml
name: docs
trigger: [push]
paths: ["**/*.swift", "docs/**"]
steps:
  - name: generate-api-docs
    run: |
      swift package generate-documentation \
        --target VoiceClone \
        --output-path ./docs/api

  - name: update-diagrams
    run: |
      python scripts/generate_diagrams.py \
        --source ./VoiceClone \
        --output ./docs/diagrams

  - name: check-links
    run: |
      markdown-link-check ./README.md ./docs/**/*.md

  - name: deploy-docs
    condition: branch == 'main'
    run: |
      # Deploy to GitHub Pages
      gh-pages -d ./docs
```

**Commands**:
```bash
# Generate all documentation
/agent docs generate

# Check documentation freshness
/agent docs check

# Deploy documentation
/agent docs deploy
```

---

### 6. Security Agent

**Purpose**: Audit code for security vulnerabilities.

**Capabilities**:
- Static analysis for security issues
- Dependency vulnerability scanning
- Privacy manifest validation
- Secret detection

**Workflow**:
```yaml
name: security
trigger: [push, pull_request]
steps:
  - name: static-analysis
    run: |
      # Run SwiftLint security rules
      swiftlint lint --config .swiftlint-security.yml

  - name: dependency-audit
    run: |
      # Check SPM dependencies
      swift package audit

  - name: secret-scan
    run: |
      # Scan for hardcoded secrets
      gitleaks detect --source . --verbose

  - name: privacy-check
    run: |
      # Validate privacy manifest
      python scripts/validate_privacy.py \
        --manifest ./VoiceClone/PrivacyInfo.xcprivacy
```

**Commands**:
```bash
# Run full security audit
/agent security audit

# Check for secrets
/agent security secrets

# Validate privacy manifest
/agent security privacy
```

---

## Agent Configuration

### Environment Variables

```bash
# Required for model conversion
export HF_TOKEN="your_huggingface_token"

# Required for iOS builds
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export CODE_SIGN_IDENTITY="Apple Development"

# Optional performance tuning
export COREML_COMPUTE_UNITS="ALL"  # or "CPU_AND_NE", "CPU_ONLY"
```

### Agent Permissions

| Agent | File Access | Network | Shell |
|-------|-------------|---------|-------|
| model-conversion | Read/Write scripts/, models/ | HuggingFace Hub | Python, pip |
| ios-build | Read/Write project | None | xcodebuild, swift |
| codegen | Write Features/, Core/ | None | None |
| performance | Read project, Write profiles/ | None | instruments, simctl |
| docs | Read/Write docs/ | GitHub Pages | swift-doc |
| security | Read all | Security advisories | gitleaks |

---

## Automation Triggers

### GitHub Actions Integration

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.2.app

      - name: Build and Test
        run: |
          # Invoke ios-build agent
          ./scripts/agent.sh ios-build run

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Security Audit
        run: |
          # Invoke security agent
          ./scripts/agent.sh security audit
```

### Local Pre-commit Hooks

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Run linting
swiftlint lint --quiet

# Check for secrets
gitleaks protect --staged --verbose

# Validate privacy manifest
python scripts/validate_privacy.py
```

---

## Agent Communication Protocol

Agents communicate via structured JSON messages:

```json
{
  "agent": "ios-build",
  "action": "test",
  "params": {
    "scheme": "VoiceClone",
    "destination": "iPhone 15 Pro",
    "coverage": true
  },
  "context": {
    "branch": "feature/voice-design",
    "commit": "abc123",
    "triggeredBy": "push"
  }
}
```

### Response Format

```json
{
  "agent": "ios-build",
  "action": "test",
  "status": "success",
  "duration": 145.2,
  "results": {
    "testsRun": 87,
    "testsPassed": 85,
    "testsFailed": 2,
    "coverage": 82.4
  },
  "artifacts": [
    "./test-results.xcresult",
    "./coverage.json"
  ],
  "logs": "https://logs.example.com/run/123"
}
```

---

## Custom Agent Development

### Agent Template

```swift
// scripts/agents/CustomAgent.swift
import Foundation

protocol Agent {
    var name: String { get }
    func run(params: [String: Any]) async throws -> AgentResult
}

struct AgentResult {
    let status: Status
    let duration: TimeInterval
    let results: [String: Any]
    let artifacts: [URL]

    enum Status: String {
        case success, failure, cancelled
    }
}

final class CustomAgent: Agent {
    let name = "custom"

    func run(params: [String: Any]) async throws -> AgentResult {
        let start = Date()

        // Implement agent logic here

        return AgentResult(
            status: .success,
            duration: Date().timeIntervalSince(start),
            results: [:],
            artifacts: []
        )
    }
}
```

### Registration

```swift
// scripts/agents/AgentRegistry.swift
final class AgentRegistry {
    static let shared = AgentRegistry()

    private var agents: [String: Agent] = [:]

    func register(_ agent: Agent) {
        agents[agent.name] = agent
    }

    func agent(named name: String) -> Agent? {
        agents[name]
    }
}

// Register agents
AgentRegistry.shared.register(ModelConversionAgent())
AgentRegistry.shared.register(IOSBuildAgent())
AgentRegistry.shared.register(CodeGenAgent())
AgentRegistry.shared.register(PerformanceAgent())
AgentRegistry.shared.register(DocsAgent())
AgentRegistry.shared.register(SecurityAgent())
```

---

## Troubleshooting

### Common Issues

| Issue | Agent | Solution |
|-------|-------|----------|
| Model conversion OOM | model-conversion | Use `--low-memory` flag or segment model |
| CoreML compilation slow | ios-build | Pre-compile models, use `.mlmodelc` |
| Tests flaky on CI | ios-build | Add retry logic, increase timeouts |
| Performance regression | performance | Compare against baseline, bisect commits |

### Debug Mode

Enable verbose logging for any agent:

```bash
/agent --debug ios-build test
```

This outputs:
- Full command traces
- Intermediate results
- Memory/CPU usage
- Timing breakdowns
