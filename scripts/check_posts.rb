#!/usr/bin/env ruby

require "yaml"
require "time"
require "date"

POSTS_DIR = ENV.fetch("POSTS_DIR", "_posts")
SEOUL_OFFSET = "+09:00"

def extract_front_matter(path)
  text = File.read(path)
  match = text.match(/\A---\n(.*?)\n---\n/m)
  return nil unless match

  YAML.load(match[1]) || {}
end

def normalize_text(value)
  value.to_s.strip.gsub(/\s+/, " ")
end

def parse_post_time(value)
  case value
  when Time
    value
  when DateTime
    Time.parse(value.to_s)
  when Date
    Time.parse(value.to_s)
  when String
    Time.parse(value)
  else
    nil
  end
end

errors = []
warnings = []
seen_titles = {}
seen_slugs = {}
now = Time.now.getlocal(SEOUL_OFFSET)
post_files = Dir.glob(File.join(POSTS_DIR, "*.md")).sort

if post_files.empty?
  errors << "no post files found in #{POSTS_DIR}"
end

post_files.each do |path|
  file_name = File.basename(path)
  match = file_name.match(/\A(\d{4}-\d{2}-\d{2})-([a-z0-9-]+)\.md\z/)

  unless match
    errors << "#{file_name}: filename must match YYYY-MM-DD-english-slug.md"
    next
  end

  file_date = match[1]
  slug = match[2]

  if seen_slugs.key?(slug)
    errors << "#{file_name}: slug '#{slug}' already used in #{seen_slugs[slug]}"
  else
    seen_slugs[slug] = file_name
  end

  data = extract_front_matter(path)
  if data.nil?
    errors << "#{file_name}: missing YAML front matter"
    next
  end

  title = normalize_text(data["title"])
  if title.empty?
    errors << "#{file_name}: missing title"
  elsif seen_titles.key?(title)
    errors << "#{file_name}: title '#{title}' already used in #{seen_titles[title]}"
  else
    seen_titles[title] = file_name
  end

  excerpt = normalize_text(data["excerpt"])
  errors << "#{file_name}: missing excerpt" if excerpt.empty?

  tags = Array(data["tags"]).map { |tag| normalize_text(tag) }.reject(&:empty?)
  if tags.empty?
    errors << "#{file_name}: tags must be a non-empty array"
  end

  unless tags.include?("Backend")
    warnings << "#{file_name}: Backend tag is missing"
  end

  date_value = data["date"]
  if date_value.nil? || normalize_text(date_value).empty?
    errors << "#{file_name}: missing date"
    next
  end

  post_time = parse_post_time(date_value)
  if post_time.nil?
    errors << "#{file_name}: date '#{date_value}' could not be parsed"
    next
  end

  seoul_time = post_time.getlocal(SEOUL_OFFSET)

  if seoul_time.strftime("%Y-%m-%d") != file_date
    errors << "#{file_name}: front matter date #{seoul_time.strftime('%Y-%m-%d')} does not match filename date #{file_date}"
  end

  if seoul_time > now
    errors << "#{file_name}: front matter date #{seoul_time.strftime('%Y-%m-%d %H:%M:%S %z')} is in the future"
  end

  unless seoul_time.strftime("%z") == "+0900"
    warnings << "#{file_name}: date offset is #{seoul_time.strftime('%z')}, expected +0900"
  end
end

if errors.empty? && warnings.empty?
  puts "OK: checked #{post_files.size} posts in #{POSTS_DIR}"
  exit 0
end

warnings.each { |warning| warn "WARNING: #{warning}" }
errors.each { |error| warn "ERROR: #{error}" }

if errors.empty?
  puts "OK WITH WARNINGS: checked #{post_files.size} posts in #{POSTS_DIR}"
  exit 0
end

warn "FAILED: checked #{post_files.size} posts in #{POSTS_DIR}"
exit 1
