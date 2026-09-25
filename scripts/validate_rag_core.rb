#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "digest"
require "json"
require "pathname"
require_relative "lib/hs_release"
require_relative "lib/hs_provenance"

ROOT = Pathname.new(File.expand_path("..", __dir__))

# version contract(統合修正仕様v1 §6): 版宣言sourceの表。principlesはtitleと内部Version:行の両方を検査する(P1-2)
VERSION_SOURCES = {
  "README current version" => ["README.md", /\*\*現行版\*\*: v(\d+\.\d+\.\d+)/],
  "README Japanese canon version" => ["README.md", /日本語正本.*?v(\d+\.\d+\.\d+)/],
  "canon/glossary internal version" => ["canon/glossary.md", /版宣言.*?v(\d+\.\d+\.\d+)/],
  "canon/principles title version" => ["canon/principles.md", /\A# 原理と定理 — KANAE（鼎）／調和的主観主義 v(\d+\.\d+\.\d+)（正本）$/],
  "canon/principles internal Version line" => ["canon/principles.md", /^Version:\s*v(\d+\.\d+\.\d+)/],
  "evaluation contract version" => ["research/rag-core-evaluation.md", /\A# Core RAG受入質問 — v(\d+\.\d+\.\d+)/]
}.freeze

# resolver: 相対path -> 本文(selftestで変異テキストを注入する)
def version_errors(expected_version, resolver)
  errors = []
  VERSION_SOURCES.each do |label, (relative, pattern)|
    text = resolver.call(relative)
    if text.nil?
      errors << "version source missing: #{label} (#{relative})"
      next
    end
    match = text.match(pattern)
    if match.nil?
      errors << "version declaration not found: #{label}"
    elsif match[1] != expected_version
      errors << "version mismatch: #{label} is v#{match[1]}, registry is v#{expected_version}"
    end
  end
  errors
end

# --selftest: version lintのtable-driven負例(各sourceを一面ずつ変異)とprovenance負例
def selftest!
  failures = []
  expected = HsRelease.registry_version
  real = lambda do |relative|
    path = ROOT.join(relative)
    path.file? ? path.read(encoding: "UTF-8") : nil
  end

  # 正例: 現repoの全宣言が一致していること
  base_errors = version_errors(expected, real)
  failures << "baseline version contract not clean: #{base_errors.join('; ')}" unless base_errors.empty?

  # 負例: 各version sourceを一面ずつv9.9.9へ変異させ、その一面だけが検出されること
  VERSION_SOURCES.each do |label, (relative, pattern)|
    mutated_resolver = lambda do |req|
      text = real.call(req)
      next text unless req == relative && text

      text.sub(pattern) { |whole| whole.sub(/\d+\.\d+\.\d+/, "9.9.9") }
    end
    errors = version_errors(expected, mutated_resolver)
    failures << "mutation not detected: #{label}" unless errors.any? { |e| e.include?(label) && e.include?("9.9.9") }
  end

  # provenance負例(P1-4): 改竄manifestが拒否されること
  live = HsProvenance.live_state
  good = {
    "schema_version" => 1, "source_commit" => live["source_commit"],
    "release_id" => live["release_id"], "pack_version" => live["pack_version"],
    "registry_sha256" => live["registry_sha256"], "generator_sha256" => live["generator_sha256"],
    "generator_path" => "scripts/build_rag_core.rb", "source_dirty" => false
  }
  failures << "provenance baseline not clean" unless HsProvenance.manifest_errors(good, live).empty?
  {
    "source_commit" => "deadbeef", "registry_sha256" => "0" * 64,
    "generator_sha256" => "0" * 64, "source_dirty" => true,
    "release_id" => "hs-v9.9.9+0000000"
  }.each do |key, forged|
    errors = HsProvenance.manifest_errors(good.merge(key => forged), live)
    failures << "forged #{key} not detected" if errors.empty?
  end

  if failures.empty?
    puts "SELFTEST PASS: #{VERSION_SOURCES.length} version mutation case(s) + 5 provenance case(s)"
    exit 0
  else
    warn "SELFTEST FAIL:"
    failures.each { |f| warn "- #{f}" }
    exit 1
  end
end

selftest! if ARGV.include?("--selftest")

# --dir <path> でstage等の検証対象rootを指定できる(既定=generated/rag)
rag_root = ROOT.join("generated/rag")
if (index = ARGV.index("--dir"))
  rag_root = Pathname.new(ARGV[index + 1] || abort("usage: validate_rag_core.rb [--dir <rag-root>] [--selftest]"))
  rag_root = ROOT.join(rag_root) if rag_root.relative?
end

CORE = rag_root.join("core")
MANIFEST_PATH = CORE.join("manifest.json")

errors = []

unless MANIFEST_PATH.file?
  warn "FAIL: missing #{MANIFEST_PATH}"
  exit 1
end

expected_version = HsRelease.registry_version

errors.concat(version_errors(expected_version, lambda { |relative|
  path = ROOT.join(relative)
  path.file? ? path.read(encoding: "UTF-8") : nil
}))

manifest = JSON.parse(MANIFEST_PATH.read(encoding: "UTF-8"))

%w[schema_version release_id pack pack_version collection_name authority source_commit source_dirty generator_path generator_sha256 registry_sha256 built_at files].each do |key|
  errors << "manifest missing key: #{key}" unless manifest.key?(key)
end
errors << "manifest pack must be harmonious-subjectivism-core" unless manifest["pack"] == "harmonious-subjectivism-core"
errors << "manifest collection_name must be harmonious-subjectivism-current" unless manifest["collection_name"] == "harmonious-subjectivism-current"
errors << "manifest authority must be current_canon" unless manifest["authority"] == "current_canon"

# provenance実値照合(P1-4): HEAD・registry・generatorのlive値へ束縛
errors.concat(HsProvenance.manifest_errors(manifest))

# receipt検査はここでは行わない。receiptはpublish成功後に発行され、
# scripts/validate_release_receipt.rb がexact release IDで照合する(P1-6)。

entries = manifest.fetch("files")
declared = entries.map { |entry| entry.fetch("file").sub("generated/rag/", "") }.sort
actual = Dir.glob(CORE.join("*.md")).map { |path| "core/#{File.basename(path)}" }.sort

errors << "manifest/file set mismatch" unless declared == actual

entries.each do |entry|
  file = rag_root.join(entry.fetch("file").sub("generated/rag/", ""))
  source = ROOT.join(entry.fetch("source_path"))

  errors << "missing generated file: #{file}" unless file.file?
  errors << "missing source file: #{source}" unless source.file?
  next unless file.file? && source.file?

  errors << "generated hash mismatch: #{file}" unless Digest::SHA256.file(file).hexdigest == entry.fetch("sha256")
  errors << "source hash mismatch: #{source}" unless Digest::SHA256.file(source).hexdigest == entry.fetch("source_sha256")

  text = file.read(encoding: "UTF-8")
  errors << "missing generated marker: #{file}" unless text.include?("generated: true") && text.include?("do_not_edit: true")
  errors << "missing transformation marker: #{file}" unless text.include?("transformation: #{entry.fetch('transformation')}")
  errors << "doc pack version mismatch: #{file}" unless text.include?("rag_pack_version: #{expected_version}")
  errors << "doc release_id mismatch: #{file}" unless text.include?("release_id: #{manifest['release_id']}")
  errors << "note URL leaked: #{file}" if text.match?(%r{https?://note\.com/}i)
  errors << "withdrawn matter definition leaked: #{file}" if text.match?(/現のうち、?源則に律される部分(?:が|＝)物質/)
  errors << "withdrawn fire definition leaked: #{file}" if text.match?(/火\s*[＝=]\s*意識/)
  errors << "withdrawn coined term leaked: #{file}" if text.include?("信火")
  errors << "raw dialogue enabled: #{file}" if text.include?("public_raw_dialogue: true")
  errors << "retired ledger leaked into core: #{file}" if text.include?("## 三、不採用・廃語台帳")
end

source_paths = entries.map { |entry| entry.fetch("source_path") }
%w[raw/ en/ zh-Hant/ docs/].each do |prefix|
  leaked = source_paths.select { |path| path.start_with?(prefix) }
  errors << "forbidden source prefix #{prefix}: #{leaked.join(', ')}" unless leaked.empty?
end

if errors.empty?
  puts "PASS: #{entries.length} core RAG document(s), version contract v#{expected_version}, provenance bound to HEAD #{manifest['source_commit'][0, 7]}"
else
  warn "FAIL: #{errors.length} RAG validation error(s)"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
