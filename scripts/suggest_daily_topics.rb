#!/usr/bin/env ruby

require "yaml"
require "time"
require "set"

POSTS_DIR = ENV.fetch("POSTS_DIR", "_posts")
POOL_PATH = ENV.fetch("TOPIC_POOL_PATH", "_data/daily_topic_pool.yml")
RECENT_DAYS = Integer(ENV.fetch("RECENT_DAYS", "7"))
SUGGEST_COUNT = Integer(ENV.fetch("SUGGEST_COUNT", "3"))

def normalize(text)
  text.to_s.strip.gsub(/\s+/, " ")
end

def load_front_matter(path)
  text = File.read(path)
  match = text.match(/\A---\n(.*?)\n---\n/m)
  return {} unless match

  YAML.load(match[1]) || {}
end

def build_category_tags(pool)
  pool.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |candidate, hash|
    category = normalize(candidate["category"])
    tag = normalize(candidate["tag"])
    next if category.empty? || tag.empty?

    hash[category] << tag unless hash[category].include?(tag)
  end
end

def category_counts(posts, category_tags)
  category_tags.each_with_object({}) do |(category, tags), hash|
    hash[category] = posts.count do |post|
      !(post[:tags] & tags).empty?
    end
  end
end

def tie_break_seed(date_key, slug)
  "#{date_key}|#{slug}".each_byte.sum
end

pool = YAML.load_file(POOL_PATH)
category_tags = build_category_tags(pool)
posts = Dir.glob(File.join(POSTS_DIR, "*.md")).sort.map do |path|
  data = load_front_matter(path)
  {
    path: path,
    file: File.basename(path),
    title: normalize(data["title"]),
    slug: File.basename(path).sub(/\A\d{4}-\d{2}-\d{2}-/, "").sub(/\.md\z/, ""),
    tags: Array(data["tags"]).map { |tag| normalize(tag) },
    time: Time.parse(data["date"].to_s)
  }
end

now = Time.now
recent_cutoff = now - (RECENT_DAYS * 24 * 60 * 60)
recent_posts = posts.select { |post| post[:time] >= recent_cutoff }
date_key = now.getlocal("+09:00").strftime("%Y-%m-%d")

used_titles = posts.map { |post| post[:title] }.to_set
used_slugs = posts.map { |post| post[:slug] }.to_set
recent_tags = recent_posts.flat_map { |post| post[:tags] }.to_set
overall_category_counts = category_counts(posts, category_tags)
recent_categories = category_tags.each_with_object(Set.new) do |(category, tags), set|
  set << category if recent_posts.any? { |post| !(post[:tags] & tags).empty? }
end
max_category_count = overall_category_counts.values.max || 0

scored = pool.map do |candidate|
  title = normalize(candidate["title"])
  slug = normalize(candidate["slug"])
  tag = normalize(candidate["tag"])
  category = normalize(candidate["category"])

  next if used_titles.include?(title)
  next if used_slugs.include?(slug)

  score = 0
  score += 3 unless recent_categories.include?(category)
  score += 2 unless recent_tags.include?(tag)
  score += 1 if category == tag
  score += (max_category_count - overall_category_counts.fetch(category, 0))

  {
    category: category,
    tag: tag,
    title: title,
    slug: slug,
    excerpt: normalize(candidate["excerpt"]),
    score: score,
    category_count: overall_category_counts.fetch(category, 0),
    tie_break: tie_break_seed(date_key, slug)
  }
end.compact

chosen = []
used_categories = Set.new

scored.sort_by { |item| [-item[:score], item[:category_count], item[:tie_break], item[:category], item[:title]] }.each do |candidate|
  next if used_categories.include?(candidate[:category])

  chosen << candidate
  used_categories << candidate[:category]
  break if chosen.size >= SUGGEST_COUNT
end

if chosen.empty?
  warn "no unused candidates available in #{POOL_PATH}"
  exit 1
end

puts "Recent posts within #{RECENT_DAYS} days: #{recent_posts.size}"
puts "Recent tags: #{recent_tags.to_a.sort.join(', ')}"
puts "Date seed: #{date_key}"
puts
puts "Suggested daily topics:"

chosen.each_with_index do |candidate, index|
  puts "#{index + 1}. [#{candidate[:category]}] #{candidate[:title]}"
  puts "   slug: #{candidate[:slug]}"
  puts "   tags: #{candidate[:tag]}, Backend"
  puts "   excerpt: #{candidate[:excerpt]}"
  puts "   coverage: #{candidate[:category_count]} existing posts in this category"
end

puts
puts "Plan file lines:"
chosen.each do |candidate|
  puts "#{candidate[:title]}|#{candidate[:slug]}|#{candidate[:tag]}|#{candidate[:excerpt]}"
end
