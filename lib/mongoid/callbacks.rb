# encoding: utf-8
module Mongoid

  # This module contains all the callback hooks for Mongoid.
  module Callbacks
    extend ActiveSupport::Concern

    CALLBACKS = [
      :after_build,
      :after_create,
      :after_destroy,
      :after_find,
      :after_initialize,
      :after_save,
      :after_update,
      :after_upsert,
      :after_validation,
      :around_create,
      :around_destroy,
      :around_save,
      :around_update,
      :around_upsert,
      :before_create,
      :before_destroy,
      :before_save,
      :before_update,
      :before_upsert,
      :before_validation
    ].freeze

    included do
      extend ActiveModel::Callbacks
      include ActiveModel::Validations::Callbacks

      define_model_callbacks :build, :find, :initialize, only: :after
      define_model_callbacks :create, :destroy, :save, :update, :upsert

      attr_accessor :before_callback_halted
    end

    # Is the provided type of callback executable by this document?
    #
    # @example Is the callback executable?
    #   document.callback_executable?(:save)
    #
    # @param [ Symbol ] kin The type of callback.
    #
    # @return [ true, false ] If the callback can be executed.
    #
    # @since 3.0.6
    def callback_executable?(kind)
      respond_to?("_#{kind}_callbacks")
    end

    # Run only the after callbacks for the specific event.
    #
    # @note ActiveSupport does not allow this type of behaviour by default, so
    #   Mongoid has to get around it and implement itself.
    #
    # @example Run only the after save callbacks.
    #   model.run_after_callbacks(:save)
    #
    # @param [ Array<Symbol> ] kinds The events that are occurring.
    #
    # @return [ Object ] The result of the chain executing.
    #
    # @since 3.0.0
    def run_after_callbacks(*kinds)
      kinds.each do |kind|
        run_targeted_callbacks(:after, kind)
      end
    end

    # Run only the before callbacks for the specific event.
    #
    # @note ActiveSupport does not allow this type of behaviour by default, so
    #   Mongoid has to get around it and implement itself.
    #
    # @example Run only the before save callbacks.
    #   model.run_before_callbacks(:save, :create)
    #
    # @param [ Array<Symbol> ] kinds The events that are occurring.
    #
    # @return [ Object ] The result of the chain executing.
    #
    # @since 3.0.0
    def run_before_callbacks(*kinds)
      kinds.each do |kind|
        run_targeted_callbacks(:before, kind)
      end
    end

    # Run the callbacks for the document. This overrides active support's
    # functionality to cascade callbacks to embedded documents that have been
    # flagged as such.
    #
    # @example Run the callbacks.
    #   run_callbacks :save do
    #     save!
    #   end
    #
    # @param [ Symbol ] kind The type of callback to execute.
    # @param [ Array ] *args Any options.
    #
    # @return [ Document ] The document
    #
    # @since 2.3.0
    def run_callbacks(kind, *args, &block)
      cascadable_children(kind).each do |child|
        unless child.run_callbacks(child_callback_type(kind, child), *args)
          return false
        end
      end
      callback_executable?(kind) ? super(kind, *args, &block) : true
    end

    private

    # We need to hook into this for autosave, since we don't want it firing if
    # the before callbacks were halted.
    #
    # @api private
    #
    # @example Was a before callback halted?
    #   document.before_callback_halted?
    #
    # @return [ true, false ] If a before callback was halted.
    #
    # @since 3.0.3
    def before_callback_halted?
      !!@before_callback_halted
    end

    # Get all the child embedded documents that are flagged as cascadable.
    #
    # @example Get all the cascading children.
    #   document.cascadable_children(:update)
    #
    # @param [ Symbol ] kind The type of callback.
    #
    # @return [ Array<Document> ] The children.
    #
    # @since 2.3.0
    def cascadable_children(kind, children = Set.new)
      embedded_relations.each_pair do |name, metadata|
        next unless metadata.cascading_callbacks?
        without_autobuild do
          delayed_pulls = delayed_atomic_pulls[name]
          delayed_unsets = delayed_atomic_unsets[name]
          children.merge(delayed_pulls) if delayed_pulls
          children.merge(delayed_unsets) if delayed_unsets
          relation = send(name)
          Array.wrap(relation).each do |child|
            next if children.include?(child)
            children.add(child) if cascadable_child?(kind, child)
            children.merge(child.send(:cascadable_children, kind, children))
          end
        end
      end
      children.to_a
    end

    # Determine if the child should fire the callback.
    #
    # @example Should the child fire the callback?
    #   document.cascadable_child?(:update, doc)
    #
    # @param [ Symbol ] kind The type of callback.
    # @param [ Document ] child The child document.
    #
    # @return [ true, false ] If the child should fire the callback.
    #
    # @since 2.3.0
    def cascadable_child?(kind, child)
      return false if [ :initialize, :find ].include?(kind) || !child.callback_executable?(kind)
      [ :create, :destroy ].include?(kind) || child.changed? || child.new_record?
    end

    # Get the name of the callback that the child should fire. This changes
    # depending on whether or not the child is new. A persisted parent with a
    # new child would fire :update from the parent, but needs to fire :create
    # on the child.
    #
    # @example Get the callback type.
    #   document.child_callback_type(:update, doc)
    #
    # @param [ Symbol ] kind The type of callback.
    # @param [ Document ] child The child document
    #
    # @return [ Symbol ] The name of the callback.
    #
    # @since 2.3.0
    def child_callback_type(kind, child)
      if kind == :update
        return :create if child.new_record?
        return :destroy if child.flagged_for_destroy?
        kind
      else
        kind
      end
    end

    # We need to hook into this for autosave, since we don't want it firing if
    # the before callbacks were halted.
    #
    # @api private
    #
    # @example Hook into the halt.
    #   document.halted_callback_hook(filter)
    #
    # @param [ Symbol ] filter The callback that halted.
    #
    # @since 3.0.3
    def halted_callback_hook(filter)
      @before_callback_halted = true
    end

    # Run only the callbacks for the target location (before, after, around)
    # and kind (save, update, create).
    #
    # @example Run the targeted callbacks.
    #   model.run_targeted_callbacks(:before, :save)
    #
    # @param [ Symbol ] place The time to run, :before, :after, :around.
    # @param [ Symbol ] kind The type of callback, :save, :create, :update.
    #
    # @return [ Object ] The result of the chain execution.
    #
    # @since 3.0.0
    def run_targeted_callbacks(place, kind)
      name = "_run__#{place}__#{kind}__callbacks"
      unless respond_to?(name)
        chain = ActiveSupport::Callbacks::CallbackChain.new(name, {})
        send("_#{kind}_callbacks").each do |callback|
          chain.push(callback) if callback.kind == place
        end
        class_eval <<-EOM
          def #{name}() #{chain.compile} end
          protected :#{name}
        EOM
      end
      send(name)
    end

    class << self

      # Get all callbacks that can be observed.
      #
      # @example Get the observables.
      #   Callbacks.observables
      #
      # @return [ Array<Symbol> ] The names of the observables.
      #
      # @since 3.1.0
      def observables
        CALLBACKS + registered_observables
      end

      # Get all registered callbacks that can be observed, not included in
      # Mongoid's defaults.
      #
      # @example Get the observables.
      #   Callbacks.registered_observables
      #
      # @return [ Array<Symbol> ] The names of the registered observables.
      #
      # @since 3.1.0
      def registered_observables
        @registered_observables ||= []
      end
    end

    module ClassMethods

      # Set a custom callback as able to be observed.
      #
      # @example Set a custom callback as observable.
      #   class Band
      #     include Mongoid::Document
      #
      #     define_model_callbacks :notification
      #     observable :notification
      #   end
      #
      # @param [ Array<Symbol> ] args The names of the observable callbacks.
      #
      # @since 3.0.1
      def observable(*args)
        observables = args.flat_map do |name|
          [ :"before_#{name}", :"after_#{name}", :"around_#{name}" ]
        end
        Callbacks.registered_observables.concat(observables).uniq
      end
    end
  end
end
