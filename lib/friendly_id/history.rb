module FriendlyId

=begin

## History: Avoiding 404's When Slugs Change

FriendlyId's {FriendlyId::History History} module adds the ability to store a
log of a model's slugs, so that when its friendly id changes, it's still
possible to perform finds by the old id.

The primary use case for this is avoiding broken URLs.

### Setup

In order to use this module, you must add a table to your database schema to
store the slug records. FriendlyId provides a generator for this purpose:

    rails generate friendly_id_globalize
    rake db:migrate

This will add a table named `friendly_id_slugs`, used by the {FriendlyId::Slug}
model.

### Considerations

Because recording slug history requires creating additional database records,
this module has an impact on the performance of the associated model's `create`
method.

### Example

    class Post < ActiveRecord::Base
      extend FriendlyId
      friendly_id :title, :use => :history
    end

    class PostsController < ApplicationController

      before_filter :find_post

      ...

      def find_post
        @post = Post.find params[:id]

        # If an old id or a numeric id was used to find the record, then
        # the request path will not match the post_path, and we should do
        # a 301 redirect that uses the current friendly id.
        if request.path != post_path(@post)
          return redirect_to @post, :status => :moved_permanently
        end
      end
    end
=end
  module History

    def self.setup(model_class)
      model_class.instance_eval do
        friendly_id_config.use :slugged
        friendly_id_config.finder_methods = FriendlyId::History::FinderMethods
        if friendly_id_config.uses? :finders
          relation.class.send(:include, friendly_id_config.finder_methods)
          if ActiveRecord::VERSION::MAJOR == 4 && ActiveRecord::VERSION::MINOR == 2
            model_class.send(:extend, friendly_id_config.finder_methods)
          end
        end
      end
    end

    # Configures the model instance to use the History add-on.
    def self.included(model_class)
      model_class.class_eval do
        has_many :slugs, -> {order(Arel.sql("#{Slug.quoted_table_name}.id DESC"))}, {
          :as         => :sluggable,
          :dependent  => :destroy,
          :class_name => Slug.to_s
        }
        after_save :create_slug

        def self.globalized?
          respond_to?(:translation_class)
        end

      end
    end

    module FinderMethods
      include ::FriendlyId::FinderMethods

      def exists_by_friendly_id?(id)
        if globalized?
          joins(:slugs, :translations).where(translation_class.arel_table[friendly_id_config.query_field].eq(id)).exists? || joins(:slugs).where(slug_history_clause(id)).exists?
        else
          joins(:slugs).where(arel_table[friendly_id_config.query_field].eq(id)).exists? || joins(:slugs).where(slug_history_clause(id)).exists?
        end
      end

      private

      def first_by_friendly_id(id)
        matching_record = where(friendly_id_config.query_field => id).first
        matching_record || slug_table_record(id)
      end

      def slug_table_record(id)
        select(quoted_table_name + '.*').joins(:slugs).where(slug_history_clause(id)).order(Slug.arel_table[:id].desc).first
      end

      def slug_history_clause(id)
        query = Slug.arel_table[:sluggable_type].eq(base_class.to_s).and(Slug.arel_table[:slug].eq(id))
        if globalized?
          return query.and(Slug.arel_table[:locale].eq(::Globalize.locale))
        else
          return query
        end
      end
    end

    private

    # If we're updating, don't consider historic slugs for the same record
    # to be conflicts. This will allow a record to revert to a previously
    # used slug.
    def scope_for_slug_generator
      relation = super
      return relation if new_record?
      relation = relation.merge(Slug.where('sluggable_id <> ?', id))
      if friendly_id_config.uses?(:scoped)
        relation = relation.where(Slug.arel_table[:scope].eq(serialized_scope))
      end
      relation
    end

    def create_slug
      if self.class.globalized?
        if self.translations.size > 1
          self.translations.map(&:locale).each do |locale|
            ::Globalize.with_locale(locale) { super_create_slug(locale) }
          end
        else
          ::Globalize.with_locale(::Globalize.locale) { super_create_slug(locale) }
        end
      else
        super_create_slug(nil)
      end
    end

    def super_create_slug(locale)
      return unless friendly_id
      return if slugs.where(locale: locale).first.try(:slug) == friendly_id
      # Allow reversion back to a previously used slug
      relation = slugs.where(slug: friendly_id, locale: locale)
      if friendly_id_config.uses?(:scoped)
        relation = relation.where(:scope => serialized_scope)
      end
      relation.delete_all
      slugs.create! do |record|
        record.slug = friendly_id
        record.locale = locale
        record.scope = serialized_scope if friendly_id_config.uses?(:scoped)
      end
    end
  end
end
