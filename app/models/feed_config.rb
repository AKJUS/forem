class FeedConfig < ApplicationRecord
  has_many :feed_events, dependent: :nullify

  def score_sql(user)
    activity_store = user.user_activity

    recent_pageviews_count = activity_store&.recently_viewed_articles&.count { |_, timestamp| timestamp.to_datetime > 24.hours.ago } || 0
    user_follow_ids = (activity_store&.alltime_users&.first(200) || user.cached_following_users_ids) + (activity_store&.recent_users&.compact || [])
    organization_follow_ids = (activity_store&.alltime_organizations&.first(200) || user.cached_following_organizations_ids) + (activity_store&.recent_organizations&.compact || [])
    subforem_follow_ids = activity_store&.alltime_subforems || []
    recent_tags_count = rand(recent_tag_count_min..recent_tag_count_max) if recent_tag_count_min.positive? && recent_tag_count_max.positive?
    all_time_tags_count = rand(all_time_tag_count_min..all_time_tag_count_max) if all_time_tag_count_min.positive? && all_time_tag_count_max.positive?
    tag_names = activity_store&.relevant_tags(recent_tags_count || 5, all_time_tags_count || 5) || user.cached_followed_tag_names
    label_names = activity_store&.recent_labels || []

    activity_tracked_pageview_time = activity_store&.recently_viewed_articles&.second
    time_of_second_latest_page_view = activity_tracked_pageview_time ? activity_tracked_pageview_time[1].to_datetime : 4.days.ago
    precomputed_selections = RecommendedArticlesList.where(user_id: user.id)
                                                     .where("expires_at > ?", Time.current)
                                                     .last&.article_ids || []
    lookback_window = time_of_second_latest_page_view - 18.hours

    languages = user.languages.pluck(:language)
    languages = [I18n.default_locale.to_s] if languages.empty?

    terms = []

    terms << "(articles.feed_success_score * #{feed_success_weight})" if feed_success_weight.positive?
    terms << "(articles.comment_score * #{comment_score_weight})" if comment_score_weight.positive?
    terms << "(articles.score * #{score_weight})" if score_weight.positive?

    if organization_follow_weight.positive?
      org_ids = organization_follow_ids.empty? ? "-1" : organization_follow_ids.join(',')
      terms << "(CASE WHEN articles.organization_id IN (#{org_ids}) THEN #{organization_follow_weight} ELSE 0 END)"
    end

    if user_follow_weight.positive?
      user_ids = user_follow_ids.empty? ? "-1" : user_follow_ids.join(',')
      terms << "(CASE WHEN articles.user_id IN (#{user_ids}) THEN #{user_follow_weight} ELSE 0 END)"
    end

    if tag_follow_weight.positive? && tag_names.present?
      tag_condition = "CASE WHEN " + tag_names.first(24).map { |tag|
        "articles.cached_tag_list ~ '[[:<:]]#{tag}[[:>:]]'"
      }.join(' OR ') + " THEN #{tag_follow_weight} ELSE 0 END"
      terms << "(#{tag_condition})"
    end

    if subforem_follow_weight.positive? &&
      RequestStore.store[:subforem_id].present? &&
      RequestStore.store[:subforem_id] == RequestStore.store[:root_subforem_id]
      subforem_ids = subforem_follow_ids.empty? ? "-1" : subforem_follow_ids.join(',')
      terms << "(CASE WHEN articles.subforem_id IN (#{subforem_ids}) THEN #{subforem_follow_weight} ELSE 0 END)"
    end

    ## Labels slightly different because we can use native Postgres array operators
    if label_match_weight.positive? && label_names.present?
      label_condition = "CASE WHEN " + label_names.map { |label|
        "? = ANY(articles.cached_label_list)"
      }.join(' OR ') + " THEN #{label_match_weight} ELSE 0 END"
      terms << "(#{label_condition})"
    end

    terms << "((1.0 / (1.0 + (EXTRACT(epoch FROM (NOW() - articles.published_at)) / 3600.0))) * #{recency_weight})" if recency_weight.positive?
    terms << "((1.0 / (1.0 + (EXTRACT(epoch FROM (NOW() - articles.last_comment_at)) / 3600.0))) * #{comment_recency_weight})" if comment_recency_weight.positive?

    if lookback_window_weight.positive?
      terms << "(CASE WHEN articles.published_at BETWEEN '#{lookback_window.utc.to_fs(:db)}' AND '#{time_of_second_latest_page_view.utc.to_fs(:db)}' THEN #{lookback_window_weight} ELSE 0 END)"
    end

    if precomputed_selections_weight.positive? && precomputed_selections.present?
      terms << "(CASE WHEN articles.id IN (#{precomputed_selections.join(',')}) THEN #{precomputed_selections_weight} ELSE 0 END)"
    end

    if recent_article_suppression_rate.positive? && activity_store
      # Compute recently viewed article IDs using the page_views table.
      recent_ids = activity_store.recently_viewed_articles.map(&:first)
      recent_ids_str = recent_ids.any? ? recent_ids.join(',') : "-1"
      terms << "(CASE WHEN articles.id IN (#{recent_ids_str}) THEN -#{recent_article_suppression_rate} ELSE 0 END)"
    end

    if published_today_weight.positive?
      published_since = 24.hours.ago.utc.to_fs(:db)
      terms << "(CASE WHEN articles.published_at >= '#{published_since}' THEN #{published_today_weight} ELSE 0 END)"
    end

    if general_past_day_bonus_weight.positive?
      published_since = 24.hours.ago.utc.to_fs(:db)
      terms << "(CASE WHEN articles.published_at >= '#{published_since}' THEN #{general_past_day_bonus_weight} ELSE 0 END)"
    end

    if recently_active_past_day_bonus_weight.positive? && recent_pageviews_count.positive?
      bonus_value = recently_active_past_day_bonus_weight * recent_pageviews_count
      published_since = 24.hours.ago.utc.to_fs(:db)
      terms << "(CASE WHEN articles.published_at >= '#{published_since}' THEN #{bonus_value} ELSE 0 END)"
    end

    if recent_subforem_weight.positive? &&
      activity_store&.recent_subforems&.any? &&
      RequestStore.store[:root_subforem_id].present? &&
      RequestStore.store[:subforem_id] == RequestStore.store[:root_subforem_id]
      ids     = activity_store.recent_subforems.compact
      arr_sql = "ARRAY[#{ids.join(',')}]::bigint[]"

      terms << <<~SQL.squish
        (
          CASE
            WHEN articles.subforem_id = ANY(#{arr_sql})
            THEN #{recent_subforem_weight}
                 * COALESCE(
                     cardinality(
                       array_positions(#{arr_sql}, articles.subforem_id)
                     ),
                     0
                   )
            ELSE 0
          END
        )
      SQL
    end

    # Additional weights
    terms << "(CASE WHEN articles.featured = TRUE THEN #{featured_weight} ELSE 0 END)" if featured_weight.positive?
    terms << "(- (articles.clickbait_score * #{clickbait_score_weight}))" if clickbait_score_weight.positive?
    terms << "(articles.compellingness_score * #{compellingness_score_weight})" if compellingness_score_weight.positive?
    terms << "(CASE WHEN articles.language IN ('#{languages.join("','")}') THEN #{language_match_weight} ELSE 0 END)" if language_match_weight.positive? && score_weight.positive?
    terms << "(RANDOM() * #{randomness_weight})" if randomness_weight.positive?

    total_expression = terms.any? ? terms.join(" + ") : "0"

    <<~SQL.squish
      (#{total_expression})
    SQL
  end

  def create_slightly_modified_clone!
    clone = dup
    clone.comment_recency_weight = comment_recency_weight * rand(0.9..1.1)
    clone.comment_score_weight = comment_score_weight * rand(0.9..1.1)
    clone.feed_success_weight = feed_success_weight * rand(0.9..1.1)
    clone.label_match_weight = label_match_weight * rand(0.9..1.1)
    clone.lookback_window_weight = lookback_window_weight * rand(0.9..1.1)
    clone.organization_follow_weight = organization_follow_weight * rand(0.9..1.1)
    clone.precomputed_selections_weight = precomputed_selections_weight * rand(0.9..1.1)
    clone.recency_weight = recency_weight * rand(0.9..1.1)
    clone.score_weight = score_weight * rand(0.9..1.1)
    clone.tag_follow_weight = tag_follow_weight * rand(0.9..1.1)
    clone.user_follow_weight = user_follow_weight * rand(0.9..1.1)
    clone.randomness_weight = randomness_weight * rand(0.9..1.1)
    clone.recent_article_suppression_rate = recent_article_suppression_rate * rand(0.9..1.1)
    clone.published_today_weight = published_today_weight * rand(0.9..1.1)
    clone.general_past_day_bonus_weight = general_past_day_bonus_weight * rand(0.9..1.1)
    clone.recently_active_past_day_bonus_weight = recently_active_past_day_bonus_weight * rand(0.9..1.1)
    clone.featured_weight = featured_weight * rand(0.9..1.1)
    clone.clickbait_score_weight = clickbait_score_weight * rand(0.9..1.1)
    clone.compellingness_score_weight = compellingness_score_weight * rand(0.9..1.1)
    clone.language_match_weight = language_match_weight * rand(0.9..1.1)
    clone.recent_subforem_weight = recent_subforem_weight * rand(0.9..1.1)
    clone.subforem_follow_weight = subforem_follow_weight * rand(0.9..1.1)
    clone.recent_tag_count_min = [recent_tag_count_min + rand(-1..1), 0].max if recent_tag_count_min.positive?
    clone.recent_tag_count_max = [recent_tag_count_max + rand(-1..1), 12].min if recent_tag_count_max.positive?
    clone.recent_tag_count_max = clone.recent_tag_count_min if clone.recent_tag_count_max < clone.recent_tag_count_min
    clone.all_time_tag_count_min = [all_time_tag_count_min + rand(-1..1), 0].max if all_time_tag_count_min.positive?
    clone.all_time_tag_count_max = [all_time_tag_count_max + rand(-1..1), 12].min if all_time_tag_count_max.positive?
    clone.all_time_tag_count_max = clone.all_time_tag_count_min if clone.all_time_tag_count_max < clone.all_time_tag_count_min
    clone.feed_impressions_count = 0
    clone.save
  end
end