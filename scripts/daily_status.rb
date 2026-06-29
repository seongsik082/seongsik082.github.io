#!/usr/bin/env ruby

require "yaml"
require "time"

POSTS_DIR = ENV.fetch("POSTS_DIR", "_posts")
SEOUL_OFFSET = "+09:00"
RECENT_DAYS = Integer(ENV.fetch("RECENT_DAYS", "7"))
POOL_PATH = ENV.fetch("TOPIC_POOL_PATH", "_data/daily_topic_pool.yml")

def load_front_matter(path)
  text = File.read(path)
  match = text.match(/\A---\n(.*?)\n---\n/m)
  return {} unless match

  YAML.load(match[1]) || {}
end

def normalize(text)
  text.to_s.strip.gsub(/\s+/, " ")
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

now = Time.now.getlocal(SEOUL_OFFSET)
today = now.strftime("%Y-%m-%d")
recent_cutoff = now - (RECENT_DAYS * 24 * 60 * 60)
pool = YAML.load_file(POOL_PATH)
category_tags = build_category_tags(pool)

posts = Dir.glob(File.join(POSTS_DIR, "*.md")).sort.map do |path|
  data = load_front_matter(path)
  {
    file: File.basename(path),
    title: normalize(data["title"]),
    tags: Array(data["tags"]).map { |tag| normalize(tag) },
    time: Time.parse(data["date"].to_s).getlocal(SEOUL_OFFSET)
  }
end

today_posts = posts.select { |post| post[:time].strftime("%Y-%m-%d") == today }
recent_posts = posts.select { |post| post[:time] >= recent_cutoff }
recent_tags = recent_posts.flat_map { |post| post[:tags] }.uniq.sort
overall_category_counts = category_counts(posts, category_tags)
recent_category_counts = category_counts(recent_posts, category_tags)
today_category_counts = category_counts(today_posts, category_tags)

puts "Date (Asia/Seoul): #{today}"
puts "Total posts: #{posts.size}"
puts "Recent #{RECENT_DAYS}-day posts: #{recent_posts.size}"
puts "Today's posts: #{today_posts.size}"
puts

if today_posts.empty?
  puts "No posts exist for today yet."
else
  puts "Today's post titles:"
  today_posts.each_with_index do |post, index|
    puts "#{index + 1}. #{post[:title]}"
    puts "   file: #{post[:file]}"
    puts "   tags: #{post[:tags].join(', ')}"
  end
end

puts
puts "Recent tags: #{recent_tags.join(', ')}"
puts
puts "Category coverage:"
overall_category_counts.sort_by { |category, count| [count, category] }.each do |category, count|
  recent_count = recent_category_counts.fetch(category, 0)
  today_count = today_category_counts.fetch(category, 0)
  puts "- #{category}: total #{count}, recent #{recent_count}, today #{today_count}"
end

underused = overall_category_counts.sort_by { |category, count| [count, category] }.first(3)
if underused.any?
  puts
  puts "Lowest coverage categories:"
  underused.each do |category, count|
    puts "- #{category} (#{count} posts)"
  end
end

puts
puts "Suggested next commands:"
if today_posts.empty?
  puts "- scripts/prepare_daily_posts.sh"
  puts "- ruby scripts/check_posts.rb"
else
  puts "- ruby scripts/check_posts.rb"
  puts "- git diff --check"
  puts "- Review today's drafts before writing body content"
  puts "- ruby scripts/suggest_daily_topics.rb"
end
