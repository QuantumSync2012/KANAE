#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rbconfig"
require "set"
require "time"
require "tmpdir"
require_relative "lib/hs_release"

# staged publish with rollback(統合修正仕様v1 §9・CF NO-GO P1-1対応):
#   1. 前提検査(quote sync・source追跡・version)
#   2. sibling stage(generated/rag.stage/)へcurrent/retiredを全量生成
#   3. manifest・lexicon・fixtureをstage内で生成
#   4-6. current/retired validator・stale-output selftestをstageに対して実行
#   7. cross-pack collision test
#   8. directory単位でpublish。第二rename以降の失敗ではactive pathを旧版へ自動復旧する
#   9-10. receipt発行+専用validator照合。失敗stageは削除せずrenameで保持
# 注: 2回のrenameは完全なatomic操作ではない。失敗時はrollbackで回復する設計である。
ROOT = Pathname.new(File.expand_path("..", __dir__))
PUBLISH_DIR = ROOT.join("generated/rag")
STAGE_DIR = ROOT.join("generated/rag.stage")
PREVIOUS_DIR = ROOT.join("generated/rag.previous")
RECEIPTS_DIR = ROOT.join("generated/receipts")

EXACT_SOURCES = %w[
  README.md
  OPEN_QUESTIONS.md
  canon/glossary.md
  canon/principles.md
  guide/ten-articles.md
  guide/why-needed.md
  guide/my-world.md
  wiki/faq.md
  wiki/heart-sutra.md
  wiki/positioning.md
].freeze

GLOB_SOURCES = %w[
  wiki/concepts/*.md
  wiki/comparisons/*.md
].freeze

FORBIDDEN_SOURCE_PREFIXES = %w[
  raw/
  en/
  zh-Hant/
  docs/
].freeze

FORBIDDEN_CONTENT = {
  "external note URL" => %r{https?://note\.com/}i,
  "withdrawn matter definition" => /現のうち、?源則に律される部分(?:が|＝)物質/,
  "withdrawn fire definition" => /火\s*[＝=]\s*意識/,
  "withdrawn coined term" => /信火/
}.freeze

STATUS_WORDS = %w[撤回 不採用 廃語].freeze

def sources
  paths = EXACT_SOURCES.map { |path| ROOT.join(path) }
  GLOB_SOURCES.each do |pattern|
    paths.concat(Dir.glob(ROOT.join(pattern)).map { |path| Pathname.new(path) })
  end
  paths.uniq.sort_by { |path| path.relative_path_from(ROOT).to_s }
end

# source globに一致するのにHEADで追跡されていないfileはfail-closedで拒否する(P1-3)。
# EDITING_POLICY.md・generated/等はそもそもsource globの外=入力外pathの明示的除外。
def untracked_sources(source_relatives, tracked_set)
  source_relatives.reject { |relative| tracked_set.include?(relative) }
end

# release buildはclean HEAD限定(再CF残件・2026-08-22)。source以外のtracked変更
# (generator・validator・登記外file含む)が1件でもあれば、生成物のcommit再現性が
# 成立しないためfail-closedで拒否する。
def tracked_dirty_guard_errors(dirty_list)
  return [] if dirty_list.empty?

  ["tracked working tree is dirty — commit or stash before release build: #{dirty_list.join(', ')}"]
end

def authority_for(relative)
  case relative
  when %r{\Acanon/}
    "current_canon"
  when "guide/ten-articles.md"
    "current_canon_summary"
  when "README.md", "guide/why-needed.md"
    "current_public_entry"
  when "OPEN_QUESTIONS.md"
    "current_open_questions"
  when %r{\Awiki/concepts/}
    "current_canon_checked_explanation"
  when %r{\Awiki/comparisons/}, "wiki/positioning.md"
    "source_scoped_comparison"
  else
    "current_canon_checked_explanation"
  end
end

def status_for(relative)
  relative == "OPEN_QUESTIONS.md" ? "open_questions" : "current"
end

def output_name(relative)
  relative.sub(/\.md\z/, "").gsub("/", "__") + ".md"
end

def strip_frontmatter(text)
  text.sub(/\A---\n.*?\n---\n/m, "")
end

RETIRED_LEDGER_PATTERN = /\n(## 三、不採用・廃語台帳\n.*?)(?=\n## |\z)/m

def prepare_for_rag(relative, text)
  prepared = strip_frontmatter(text)
  return prepared unless relative == "canon/glossary.md"

  prepared.sub(RETIRED_LEDGER_PATTERN, "\n")
end

# 廃語台帳は current pack に入れない(validate_rag_core が撤回語の混入を fail-closed で禁じている)。
# 「現行の答えとして返さない」を保ったまま「撤回された事実には到達できる」を両立させるため、
# 別スコープ retired/ へ出し、qmd では別コレクションとして索引する(2026-08-21、別collection化=2026-08-22仕様v1)。
def extract_retired_ledger(text)
  match = strip_frontmatter(text).match(RETIRED_LEDGER_PATTERN)
  match && match[1]
end

# 台帳表の行から語を引く。label=表記全体、bare=括弧注記を除いた検索語
def ledger_words(ledger_text)
  ledger_text.lines.map do |line|
    next unless line.start_with?("| ")
    next if line.start_with?("| 語 ")

    label = line.split("|")[1].to_s.strip.gsub(%r{<a id="[^"]*"></a>}, "").strip
    next if label.empty?

    { "label" => label, "bare" => label.sub(/[（(].*\z/, "").strip }
  end.compact
end

def retired_doc_header(source_sha, pack_version, release_id)
  <<~YAML
    ---
    generated: true
    do_not_edit: true
    rag_pack: harmonious-subjectivism-retired
    rag_pack_version: #{pack_version}
    release_id: #{release_id}
    authority: current_canon
    status: retired_ledger
    source_path: canon/glossary.md
    source_sha256: #{source_sha}
    transformation: retired_ledger_extracted
    ---

    > この文書は**撤回・不採用となった語の台帳**である。ここに載る語は現行の体系語ではない。
    > 「その語は撤回されたか」への回答根拠であり、現行の定義として引用してはならない。

  YAML
end

def fixture_cases(words)
  cases = []
  words.each do |word|
    bare = word.fetch("bare")
    base_gate = {
      "must_include_any" => STATUS_WORDS,
      "must_not_patterns" => ["#{bare}とは.+である(?!.*(撤回|不採用|廃語))"]
    }
    {
      "explain_old" => ["「#{bare}」というかつての語の説明", "retired"],
      "is_current" => ["「#{bare}」は現行の体系語か", "retired"],
      "diff_from_current" => ["「#{bare}」と現行の体系語との違い", "retired"],
      # current質問へのretired語混入(collision): defaultはcurrentが答え、retiredが順位を奪わない
      "collision_mixed" => ["#{bare}という言葉を使わずに、対応する現行の考え方を説明して", "current_priority"]
    }.each do |intent, (query, scope)|
      cases << {
        "id" => "#{bare}:#{intent}",
        "word" => bare, "intent" => intent, "query" => query,
        "expected_scope" => scope,
        "answer_gate" => scope == "retired" ? base_gate : { "must_not_patterns" => base_gate["must_not_patterns"] }
      }
    end
  end
  cases
end

def build_stage!(stage)
  pack_version = HsRelease.pack_version
  release_id = HsRelease.release_id

  FileUtils.rm_rf(stage)
  current_dir = stage.join("core")
  retired_dir = stage.join("retired")
  FileUtils.mkdir_p(current_dir)
  FileUtils.mkdir_p(retired_dir)

  source_relatives = sources.map { |path| path.relative_path_from(ROOT).to_s }
  untracked = untracked_sources(source_relatives, HsRelease.tracked_files.to_set)
  unless untracked.empty?
    raise "untracked source file(s) — commit or remove before building: #{untracked.join(', ')}"
  end

  generator_sha = Digest::SHA256.file(__FILE__).hexdigest
  built_at = Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z")
  source_dirty = !HsRelease.dirty_paths(source_relatives + ["research/hs-id-registry.yaml"]).empty?
  retired_outputs = []
  glossary_sha = nil
  ledger = nil

  entries = sources.map do |source|
    raise "missing source: #{source}" unless source.file?

    relative = source.relative_path_from(ROOT).to_s
    source_text = source.read(encoding: "UTF-8")
    rag_text = prepare_for_rag(relative, source_text)

    if FORBIDDEN_SOURCE_PREFIXES.any? { |prefix| relative.start_with?(prefix) }
      raise "forbidden source path: #{relative}"
    end
    FORBIDDEN_CONTENT.each do |label, pattern|
      raise "#{label} in #{relative}" if rag_text.match?(pattern)
    end
    raise "raw dialogue marked public in #{relative}" if rag_text.include?("public_raw_dialogue: true")

    source_sha = Digest::SHA256.hexdigest(source_text)
    if relative == "canon/glossary.md"
      glossary_sha = source_sha
      ledger = extract_retired_ledger(source_text)
    end

    target = current_dir.join(output_name(relative))
    transformation = relative == "canon/glossary.md" ? "retired_ledger_excluded" : "frontmatter_removed"
    metadata = <<~YAML
      ---
      generated: true
      do_not_edit: true
      rag_pack: harmonious-subjectivism-core
      rag_pack_version: #{pack_version}
      release_id: #{release_id}
      authority: #{authority_for(relative)}
      status: #{status_for(relative)}
      source_path: #{relative}
      source_sha256: #{source_sha}
      transformation: #{transformation}
      ---

    YAML
    target.write(metadata + rag_text, encoding: "UTF-8")

    {
      "file" => "generated/rag/core/#{target.basename}",
      "sha256" => Digest::SHA256.file(target).hexdigest,
      "source_path" => relative,
      "source_sha256" => source_sha,
      "transformation" => transformation,
      "authority" => authority_for(relative),
      "status" => status_for(relative)
    }
  end

  raise "retired ledger section not found in canon/glossary.md" unless ledger

  # retired: 台帳doc + lexicon + 動的fixture(台帳全行から機械列挙・語数を恒久定数にしない)
  ledger_doc = retired_dir.join("canon__glossary__retired-ledger.md")
  ledger_doc.write(retired_doc_header(glossary_sha, pack_version, release_id) + ledger + "\n", encoding: "UTF-8")
  words = ledger_words(ledger)
  raise "retired ledger has no word rows" if words.empty?

  lexicon = {
    "schema_version" => 1, "release_id" => release_id,
    "source_path" => "canon/glossary.md", "source_sha256" => glossary_sha,
    "words" => words
  }
  lexicon_path = retired_dir.join("retired-lexicon.json")
  lexicon_path.write(JSON.pretty_generate(lexicon) + "\n", encoding: "UTF-8")

  fixture = {
    "schema_version" => 1, "release_id" => release_id,
    "source_sha256" => glossary_sha, "generated_at" => built_at,
    "word_count" => words.length,
    "status_words" => STATUS_WORDS,
    "cases" => fixture_cases(words)
  }
  fixture_path = retired_dir.join("retired-fixture.json")
  fixture_path.write(JSON.pretty_generate(fixture) + "\n", encoding: "UTF-8")

  [ledger_doc, lexicon_path, fixture_path].each do |path|
    retired_outputs << {
      "file" => "generated/rag/retired/#{path.basename}",
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "source_path" => "canon/glossary.md",
      "source_sha256" => glossary_sha
    }
  end

  manifest_common = {
    "schema_version" => 1,
    "release_id" => release_id,
    "pack_version" => pack_version,
    "language" => "ja",
    "source_commit" => HsRelease.source_commit,
    "source_dirty" => source_dirty,
    "generator_path" => "scripts/build_rag_core.rb",
    "generator_sha256" => generator_sha,
    "registry_sha256" => HsRelease.registry_sha256,
    "built_at" => built_at
  }

  current_manifest = manifest_common.merge(
    "pack" => "harmonious-subjectivism-core",
    "collection_name" => "harmonious-subjectivism-current",
    "authority" => "current_canon",
    "scope" => "current Japanese canon-checked public explanations",
    "excluded" => [
      "raw dialogue",
      "dictionary raw transcription",
      "historical translations",
      "v0.1.1 publication tree",
      "retired or rejected definitions as current answers"
    ],
    "files" => entries
  )
  current_dir.join("manifest.json").write(JSON.pretty_generate(current_manifest) + "\n", encoding: "UTF-8")

  retired_manifest = manifest_common.merge(
    "pack" => "harmonious-subjectivism-retired",
    "collection_name" => "harmonious-subjectivism-retired",
    "authority" => "current_canon",
    "status" => "retired_ledger",
    "scope" => "retired and rejected terms as status evidence, never as current definitions",
    "word_count" => words.length,
    "fixture_sha256" => Digest::SHA256.file(fixture_path).hexdigest,
    "lexicon_sha256" => Digest::SHA256.file(lexicon_path).hexdigest,
    "files" => retired_outputs
  )
  retired_dir.join("manifest.json").write(JSON.pretty_generate(retired_manifest) + "\n", encoding: "UTF-8")

  entries.length + retired_outputs.length
end

# cross-pack collision test(仕様§9手順7): 両packの出力が重複せず、authority境界が混ざらないこと
def cross_pack_collisions(rag_root)
  errors = []
  core_manifest = rag_root.join("core/manifest.json")
  retired_manifest = rag_root.join("retired/manifest.json")
  return ["missing manifest(s) for collision test"] unless core_manifest.file? && retired_manifest.file?

  core_files = JSON.parse(core_manifest.read(encoding: "UTF-8")).fetch("files").map { |e| e.fetch("file") }
  retired_files = JSON.parse(retired_manifest.read(encoding: "UTF-8")).fetch("files").map { |e| e.fetch("file") }
  overlap = core_files & retired_files
  errors << "output file(s) listed in both packs: #{overlap.join(', ')}" unless overlap.empty?

  Dir.glob(rag_root.join("core/*.md")).each do |path|
    text = File.read(path, encoding: "UTF-8")
    errors << "retired authority marker inside current pack: #{path}" if text.include?("status: retired_ledger")
  end
  errors << "retired ledger doc found under core/" if rag_root.join("core/canon__glossary__retired-ledger.md").exist?
  errors
end

# publish: 2回のrenameで置換し、第二rename以降の失敗ではactiveを旧版へ自動復旧する(P1-1)。
# moverはselftestで失敗を注入するための注入点。復旧そのものは常にFileUtils.mvで行う。
def publish_with_rollback!(stage, publish, previous, mover: FileUtils.method(:mv))
  FileUtils.rm_rf(previous)
  had_active = publish.exist?
  mover.call(publish.to_s, previous.to_s) if had_active
  begin
    mover.call(stage.to_s, publish.to_s)
  rescue StandardError
    FileUtils.mv(previous.to_s, publish.to_s) if had_active && previous.exist? && !publish.exist?
    raise
  end
end

# publish後の検証・receipt失敗時: 新artifactを退避し旧版をactiveへ戻す(P1-1)
def rollback_published!(publish, previous, reason)
  failed = ROOT.join("generated/rag.published.failed-#{Time.now.strftime('%Y%m%dT%H%M%S')}")
  FileUtils.mv(publish.to_s, failed.to_s) if publish.exist?
  FileUtils.mv(previous.to_s, publish.to_s) if previous.exist?
  warn "published artifact rolled back (#{reason}); failed output preserved: #{failed}"
end

def run_step!(label, *command)
  puts "-- #{label}"
  return if system(*command, chdir: ROOT.to_s)

  raise "step failed: #{label}"
end

def write_receipt!(status, error: nil)
  RECEIPTS_DIR.mkpath
  stamp = Time.now.strftime("%Y%m%dT%H%M%S")
  receipt = {
    "schema_version" => 1,
    "release_id" => HsRelease.release_id,
    "pack_version" => HsRelease.pack_version,
    "status" => status,
    "source_commit" => HsRelease.source_commit,
    "built_at" => Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z"),
    "published_path" => "generated/rag",
    "previous_path" => PREVIOUS_DIR.exist? ? "generated/rag.previous" : nil,
    "error" => error
  }
  path = RECEIPTS_DIR.join("#{HsRelease.release_id.gsub('+', '_')}_build_#{stamp}_#{status}.json")
  path.write(JSON.pretty_generate(receipt) + "\n", encoding: "UTF-8")
  puts "Receipt: #{path}"
  path
end

# --selftest: publish失敗系とuntracked source拒否を合成環境で検証(非LLM・exit判定)
def selftest!
  failures = []
  Dir.mktmpdir("hs-build-selftest") do |tmp|
    tmp = Pathname.new(tmp)

    # case 1: 第二rename失敗 → activeが自動復旧されること
    stage = tmp.join("rag.stage"); publish = tmp.join("rag"); previous = tmp.join("rag.previous")
    stage.mkpath; publish.mkpath
    publish.join("marker.txt").write("old-active", encoding: "UTF-8")
    calls = 0
    failing_mover = lambda do |src, dst|
      calls += 1
      raise "injected mv failure" if calls == 2

      FileUtils.mv(src, dst)
    end
    begin
      publish_with_rollback!(stage, publish, previous, mover: failing_mover)
      failures << "case1: injected failure did not raise"
    rescue StandardError
      failures << "case1: active path not restored" unless publish.join("marker.txt").exist?
    end

    # case 2: 正常publish → 新版がactive・旧版がpreviousに残ること
    stage2 = tmp.join("s2/rag.stage"); publish2 = tmp.join("s2/rag"); previous2 = tmp.join("s2/rag.previous")
    stage2.mkpath; publish2.mkpath
    stage2.join("marker.txt").write("new", encoding: "UTF-8")
    publish2.join("marker.txt").write("old", encoding: "UTF-8")
    publish_with_rollback!(stage2, publish2, previous2)
    failures << "case2: new artifact not active" unless publish2.join("marker.txt").read == "new"
    failures << "case2: previous not preserved" unless previous2.join("marker.txt").read == "old"

    # case 3: published検証失敗のrollback → 旧版がactiveへ戻り、失敗出力が保存されること
    pub3 = tmp.join("s3/rag"); prev3 = tmp.join("s3/rag.previous")
    pub3.mkpath; prev3.mkpath
    pub3.join("marker.txt").write("bad-new", encoding: "UTF-8")
    prev3.join("marker.txt").write("good-old", encoding: "UTF-8")
    stub_root = tmp.join("s3")
    failed_dirs_before = Dir.glob(ROOT.join("generated/rag.published.failed-*")).length
    # rollback_published!はROOT配下へfailedを退避するため、ここでは直接同等手順を検証する
    failed3 = stub_root.join("rag.failed")
    FileUtils.mv(pub3.to_s, failed3.to_s)
    FileUtils.mv(prev3.to_s, pub3.to_s)
    failures << "case3: old artifact not restored" unless pub3.join("marker.txt").read == "good-old"
    failures << "case3: failed output not preserved" unless failed3.join("marker.txt").read == "bad-new"
    failures << "case3: unexpected failed dirs in repo" unless Dir.glob(ROOT.join("generated/rag.published.failed-*")).length == failed_dirs_before

    # case 4: untracked source拒否(P1-3)
    untracked = untracked_sources(%w[canon/glossary.md wiki/comparisons/new-page.md], Set.new(%w[canon/glossary.md]))
    failures << "case4: untracked source not detected" unless untracked == %w[wiki/comparisons/new-page.md]
    failures << "case4: tracked source misflagged" unless untracked_sources(%w[canon/glossary.md], Set.new(%w[canon/glossary.md])).empty?

    # case 5: tracked dirty(generator変更を含む)はrelease buildを拒否(再CF残件)
    errors = tracked_dirty_guard_errors(%w[scripts/build_rag_core.rb])
    failures << "case5: dirty generator not refused" if errors.empty?
    errors = tracked_dirty_guard_errors(%w[canon/glossary.md wiki/faq.md])
    failures << "case5: dirty tracked sources not refused" if errors.empty?

    # case 6: clean HEADは通す
    failures << "case6: clean tree refused" unless tracked_dirty_guard_errors([]).empty?
  end

  if failures.empty?
    puts "SELFTEST PASS: 6 case(s)"
    exit 0
  else
    warn "SELFTEST FAIL:"
    failures.each { |f| warn "- #{f}" }
    exit 1
  end
end

selftest! if ARGV.include?("--selftest")

begin
  # 0. clean HEAD gate: tracked変更が1件でもあればrelease buildを開始しない(fail-closed)
  guard = tracked_dirty_guard_errors(HsRelease.dirty_paths)
  raise guard.first unless guard.empty?

  # 1. 前提検査
  run_step!("canonical definition quote check",
            RbConfig.ruby, ROOT.join("scripts/sync_definition_quotes.rb").to_s, "--check")

  # 2-3. stageへ全量生成
  total = build_stage!(STAGE_DIR)
  puts "-- staged #{total} artifact(s) in #{STAGE_DIR}"

  # 4-6. stageに対する検証(current・retired・stale-output selftest)
  run_step!("current pack validation (stage)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_core.rb").to_s, "--dir", STAGE_DIR.to_s)
  run_step!("retired pack validation (stage)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s, "--dir", STAGE_DIR.to_s)
  run_step!("stale-output rejection selftest",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s, "--selftest")

  # 7. cross-pack collision test
  puts "-- cross-pack collision test"
  collisions = cross_pack_collisions(STAGE_DIR)
  raise "collision test failed: #{collisions.join('; ')}" unless collisions.empty?

  # 8. staged publish with rollback
  publish_with_rollback!(STAGE_DIR, PUBLISH_DIR, PREVIOUS_DIR)

  begin
    # publish後の最終検証(公開位置でもPASSすることを確認)
    run_step!("current pack validation (published)",
              RbConfig.ruby, ROOT.join("scripts/validate_rag_core.rb").to_s)
    run_step!("retired pack validation (published)",
              RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s)

    # 9-10. receipt発行+専用validatorでの照合(P1-6: stage検証から分離・exact release ID)
    receipt_path = write_receipt!("pass")
    run_step!("release receipt validation",
              RbConfig.ruby, ROOT.join("scripts/validate_release_receipt.rb").to_s, receipt_path.to_s)
  rescue StandardError => e
    rollback_published!(PUBLISH_DIR, PREVIOUS_DIR, e.message)
    raise
  end

  puts "Built and published #{HsRelease.release_id} to #{PUBLISH_DIR}"
rescue StandardError => e
  # 失敗stageは削除せず保持(統合修正仕様v1 §9)。activeは上のrollbackで旧版へ戻っている。
  if STAGE_DIR.exist?
    failed = ROOT.join("generated/rag.stage.failed-#{Time.now.strftime('%Y%m%dT%H%M%S')}")
    FileUtils.mv(STAGE_DIR, failed)
    warn "failed stage preserved: #{failed}"
  end
  write_receipt!("fail", error: e.message)
  abort "FAIL: #{e.message}"
end
