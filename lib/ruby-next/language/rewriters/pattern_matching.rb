# frozen_string_literal: true

module RubyNext
  module Language
    module Rewriters
      using RubyNext

      using(Module.new do
        refine ::Parser::AST::Node do
          def to_ast_node
            self
          end
        end

        refine String do
          def to_ast_node
            ::Parser::AST::Node.new(:str, [self])
          end
        end

        refine Symbol do
          def to_ast_node
            ::Parser::AST::Node.new(:sym, [self])
          end
        end

        refine Integer do
          def to_ast_node
            ::Parser::AST::Node.new(:int, [self])
          end
        end
      end)

      # We can memoize structural predicates to avoid double calculation.
      #
      # For example, consider the following case and the corresponding predicate chains:
      #
      #    case val
      #    in [:ok, 200] #=> [:respond_to_deconstruct, :deconstruct_type, :arr_size_is_2]
      #    in [:created, 201] #=> [:respond_to_deconstruct, :deconstruct_type, :arr_size_is_2]
      #    in [401 | 403] #=> [:respond_to_deconstruct, :deconstruct_type, :arr_size_is_1]
      #    end
      #
      # We can minimize the number of predicate calls by storing the intermediate values (prefixed with `p_`) and using them
      # in the subsequent calls:
      #
      #    case val
      #    in [:ok, 200] #=> [:respond_to_deconstruct, :deconstruct_type, :arr_size_is_2]
      #    in [:created, 201] #=> [:p_deconstructed, :p_arr_size_2]
      #    in [401 | 403] #=> [:p_deconstructed, :arr_size_is_1]
      #    end
      #
      # This way we mimic a naive decision tree algorithim.
      module Predicates
        class Processor < ::Parser::TreeRewriter
          attr_reader :predicates

          def initialize(predicates)
            @predicates = predicates
            super()
          end

          def on_lvasgn(node)
            lvar, val = *node.children
            if predicates.store[lvar] == false
              process(val)
            else
              node
            end
          end

          def on_and(node)
            left, right = *node.children

            if truthy(left)
              process(right)
            elsif truthy(right)
              process(left)
            else
              node.updated(
                :and,
                [
                  process(left),
                  process(right)
                ]
              )
            end
          end

          private

          def truthy(node)
            return false unless node.is_a?(::Parser::AST::Node)
            return true if node.type == :true
            return false if node.children.empty?

            node.children.all? { |child| truthy(child) }
          end
        end

        class Base
          attr_reader :store, :predicates_by_path, :count, :terminated, :current_path
          alias terminated? terminated

          def initialize
            # total number of predicates
            @count = 0
            # cache of all predicates by path
            @predicates_by_path = {}
            # all predicates and their dirty state
            @store = {}

            @current_path = []
          end

          def reset!
            @current_path = []
            @terminated = false
          end

          def push(path)
            current_path << path
          end

          def pop
            current_path.pop
          end

          def terminate!
            @terminated = true
          end

          def predicate_clause(name, node)
            if pred?(name)
              read_pred(name)
            else
              write_pred(name, node)
            end
          end

          def pred?(name)
            predicates_by_path.key?(current_path + [name])
          end

          def read_pred(name)
            lvar = predicates_by_path.fetch(current_path + [name])
            # mark as used
            store[lvar] = true
            s(:lvar, lvar)
          end

          def write_pred(name, node)
            return node if terminated?
            @count += 1
            lvar = :"__p_#{count}__"
            predicates_by_path[current_path + [name]] = lvar
            store[lvar] = false

            s(:lvasgn,
              lvar,
              node)
          end

          def process(ast)
            Processor.new(self).process(ast)
          end

          private

          def s(type, *children)
            ::Parser::AST::Node.new(type, children)
          end
        end

        # rubocop:disable Style/MethodMissingSuper
        # rubocop:disable Style/MissingRespondToMissing
        class Noop < Base
          # Return node itself, no memoization
          def method_missing(mid, node, *)
            node
          end
        end
        # rubocop:enable Style/MethodMissingSuper
        # rubocop:enable Style/MissingRespondToMissing

        class CaseIn < Base
          def const(node, const)
            node
          end

          def respond_to_deconstruct(node)
            predicate_clause(:respond_to_deconstruct, node)
          end

          def array_size(node, size)
            predicate_clause(:"array_size_#{size}", node)
          end

          def array_deconstructed(node)
            predicate_clause(:array_deconstructed, node)
          end

          def hash_deconstructed(node, keys)
            predicate_clause(:"hash_deconstructed_#{keys.join("_p_")}", node)
          end

          def respond_to_deconstruct_keys(node)
            predicate_clause(:respond_to_deconstruct_keys, node)
          end

          def hash_key(node, key)
            key = key.children.first if key.is_a?(::Parser::AST::Node)
            predicate_clause(:"hash_key_#{key}", node)
          end
        end
      end

      class PatternMatching < Base
        SYNTAX_PROBE = "case 0; in 0; true; else; 1; end"
        MIN_SUPPORTED_VERSION = Gem::Version.new("2.7.0")

        MATCHEE = :__m__
        MATCHEE_ARR = :__m_arr__
        MATCHEE_HASH = :__m_hash__

        ALTERNATION_MARKER = :__alt__
        CURRENT_HASH_KEY = :__chk__

        def on_case_match(node)
          context.track! self

          @deconstructed_keys = {}
          @predicates = Predicates::CaseIn.new

          matchee_ast =
            s(:lvasgn, MATCHEE, node.children[0])

          patterns = locals.with(
            matchee: MATCHEE,
            arr: MATCHEE_ARR,
            hash: MATCHEE_HASH
          ) do
            build_case_when(node.children[1..-1])
          end

          predicates.process(
            node.updated(
              :begin,
              [
                matchee_ast, s(:case, *patterns)
              ]
            )
          )
        end

        def on_in_match(node)
          context.track! self

          @deconstructed_keys = {}
          @predicates = Predicates::Noop.new

          matchee =
            s(:lvasgn, MATCHEE, node.children[0])

          pattern =
            locals.with(
              matchee: MATCHEE,
              arr: MATCHEE_ARR,
              hash: MATCHEE_HASH
            ) do
              send(
                :"#{node.children[1].type}_clause",
                node.children[1]
              ).then do |node|
                s(:or,
                  node,
                  no_matching_pattern)
              end
            end

          node.updated(
            :and,
            [
              matchee,
              pattern
            ]
          )
        end

        private

        def build_case_when(nodes)
          else_clause = nil
          clauses = []

          nodes.each do |clause|
            if clause&.type == :in_pattern
              clauses << build_when_clause(clause)
            else
              else_clause = process(clause)
            end
          end

          else_clause = (else_clause || no_matching_pattern).then do |node|
            next node unless node.type == :empty_else
            s(:empty)
          end

          clauses << else_clause
          clauses
        end

        def build_when_clause(clause)
          predicates.reset!
          [
            with_guard(
              send(
                :"#{clause.children[0].type}_clause",
                clause.children[0]
              ),
              clause.children[1] # guard
            ),
            process(clause.children[2] || s(:nil)) # expression
          ].then do |children|
            s(:when, *children)
          end
        end

        def const_pattern_clause(node, right = s(:lvar, locals[:matchee]))
          const, pattern = *node.children

          predicates.const(case_eq_clause(const, right), const).then do |node|
            next node if pattern.nil?

            s(:and,
              node,
              send(:"#{pattern.type}_clause", pattern))
          end
        end

        def match_alt_clause(node)
          children = locals.with(ALTERNATION_MARKER => true) do
            node.children.map.with_index do |child, i|
              predicates.terminate! if i == 1
              send :"#{child.type}_clause", child
            end
          end
          s(:or, *children)
        end

        def match_as_clause(node, right = s(:lvar, locals[:matchee]))
          s(:and,
            send(:"#{node.children[0].type}_clause", node.children[0], right),
            match_var_clause(node.children[1], right))
        end

        def match_var_clause(node, left = s(:lvar, locals[:matchee]))
          return s(:true) if node.children[0] == :_

          check_match_var_alternation! node.children[0]

          s(:or,
            s(:lvasgn, node.children[0], left),
            s(:true))
        end

        def pin_clause(node, right = s(:lvar, locals[:matchee]))
          predicates.terminate!
          case_eq_clause node.children[0], right
        end

        def case_eq_clause(node, right = s(:lvar, locals[:matchee]))
          predicates.terminate!
          s(:send,
            process(node), :===, right)
        end

        #=========== ARRAY PATTERN (START) ===============

        def array_pattern_clause(node, matchee = s(:lvar, locals[:matchee]))
          deconstruct_node(matchee).then do |dnode|
            size_check = nil
            # if there is no rest or tail, match the size first
            unless node.type == :array_pattern_with_tail || node.children.any? { |n| n.type == :match_rest }
              size_check = predicates.array_size(
                s(:send,
                  node.children.size.to_ast_node,
                  :==,
                  s(:send, s(:lvar, locals[:arr]), :size)),
                node.children.size
              )
            end

            right =
              if node.children.empty?
                case_eq_clause(s(:array), s(:lvar, locals[:arr]))
              else
                array_element(0, *node.children)
              end

            right = s(:and, size_check, right) if size_check

            s(:and,
              dnode,
              right)
          end
        end

        alias array_pattern_with_tail_clause array_pattern_clause

        def deconstruct_node(matchee)
          context.use_ruby_next!

          # we do not memoize respond_to_check for arrays, 'cause
          # we can memoize is together with #deconstruct result
          respond_check = respond_to_check(matchee, :deconstruct)
          right = s(:send, matchee, :deconstruct)

          predicates.array_deconstructed(
            s(:and,
              respond_check,
              s(:and,
                s(:or,
                  s(:lvasgn, locals[:arr], right),
                  s(:true)),
                s(:or,
                  s(:send,
                    s(:const, nil, :Array), :===, s(:lvar, locals[:arr])),
                  raise_error(:TypeError, "#deconstruct must return Array"))))
          )
        end

        def array_element(index, head, *tail)
          return array_match_rest(index, head, *tail) if head.type == :match_rest

          send("#{head.type}_array_element", head, index).then do |node|
            next node if tail.empty?

            s(:and,
              node,
              array_element(index + 1, *tail))
          end
        end

        def array_match_rest(index, node, *tail)
          child = node.children[0]
          rest = arr_rest_items(index, tail.size).then do |r|
            next r unless child

            match_var_clause(
              child,
              r
            )
          end

          return rest if tail.empty?

          s(:and,
            rest,
            array_rest_element(*tail))
        end

        def array_rest_element(head, *tail)
          send("#{head.type}_array_element", head, -(tail.size + 1)).then do |node|
            next node if tail.empty?

            s(:and,
              node,
              array_rest_element(*tail))
          end
        end

        def array_pattern_array_element(node, index)
          element = arr_item_at(index)
          locals.with(arr: locals[:arr, index]) do
            predicates.push :"i#{index}"
            array_pattern_clause(node, element).tap { predicates.pop }
          end
        end

        def hash_pattern_array_element(node, index)
          element = arr_item_at(index)
          locals.with(hash: locals[:arr, index]) do
            predicates.push :"i#{index}"
            hash_pattern_clause(node, element).tap { predicates.pop }
          end
        end

        def match_alt_array_element(node, index)
          children = node.children.map do |child, i|
            send :"#{child.type}_array_element", child, index
          end
          s(:or, *children)
        end

        def match_var_array_element(node, index)
          match_var_clause(node, arr_item_at(index))
        end

        def match_as_array_element(node, index)
          match_as_clause(node, arr_item_at(index))
        end

        def pin_array_element(node, index)
          case_eq_array_element node.children[0], index
        end

        def case_eq_array_element(node, index)
          case_eq_clause(node, arr_item_at(index))
        end

        def arr_item_at(index, arr = s(:lvar, locals[:arr]))
          s(:index, arr, index.to_ast_node)
        end

        def arr_rest_items(index, size, arr = s(:lvar, locals[:arr]))
          s(:index,
            arr,
            s(:irange,
              s(:int, index),
              s(:int, -(size + 1))))
        end

        #=========== ARRAY PATTERN (END) ===============

        #=========== HASH PATTERN (START) ===============

        def hash_pattern_clause(node, matchee = s(:lvar, locals[:matchee]))
          # Optimization: avoid hash modifications when not needed
          # (we use #dup and #delete when "reading" values when **rest is present
          # to assign the rest of the hash copy to it)
          @hash_match_rest = node.children.any? { |child| child.type == :match_rest || child.type == :match_nil_pattern }
          keys = hash_pattern_destruction_keys(node.children)

          specified_key_names = hash_pattern_keys(node.children)

          deconstruct_keys_node(keys, matchee).then do |dnode|
            right =
              if node.children.empty?
                case_eq_clause(s(:hash), s(:lvar, locals[:hash]))
              elsif specified_key_names.empty?
                hash_element(*node.children)
              else
                s(:and,
                  having_hash_keys(specified_key_names),
                  hash_element(*node.children))
              end

            predicates.pop

            next dnode if right.nil?

            s(:and,
              dnode,
              right)
          end
        end

        def hash_pattern_keys(children)
          children.filter_map do |child|
            # Skip ** without var
            next if child.type == :match_rest || child.type == :match_nil_pattern

            send("#{child.type}_hash_key", child)
          end
        end

        def hash_pattern_destruction_keys(children)
          return s(:nil) if children.empty?

          children.filter_map do |child|
            # Skip ** without var
            next if child.type == :match_rest && child.children.empty?
            return s(:nil) if child.type == :match_rest || child.type == :match_nil_pattern

            send("#{child.type}_hash_key", child)
          end.then { |keys| s(:array, *keys) }
        end

        def pair_hash_key(node)
          node.children[0]
        end

        def match_var_hash_key(node)
          check_match_var_alternation! node.children[0]

          s(:sym, node.children[0])
        end

        def deconstruct_keys_node(keys, matchee = s(:lvar, locals[:matchee]))
          # Use original hash returned by #deconstruct_keys if not **rest matching,
          # 'cause it remains immutable
          deconstruct_name = @hash_match_rest ? locals[:hash, :src] : locals[:hash]

          # Duplicate the source hash when matching **rest, 'cause we mutate it
          hash_dup =
            if @hash_match_rest
              s(:lvasgn, locals[:hash], s(:send, s(:lvar, locals[:hash, :src]), :dup))
            else
              s(:true)
            end

          context.use_ruby_next!

          respond_to_checked = predicates.pred?(:respond_to_deconstruct_keys)
          respond_check = predicates.respond_to_deconstruct_keys(respond_to_check(matchee, :deconstruct_keys))

          key_names = keys.children.map { |node| node.children.last }
          predicates.push locals[:hash]

          s(:lvasgn, deconstruct_name,
            s(:send,
              matchee, :deconstruct_keys, keys)).then do |dnode|
            next dnode if respond_to_checked

            s(:and,
              respond_check,
              s(:and,
                s(:or,
                  dnode,
                  s(:true)),
                s(:or,
                  s(:send,
                    s(:const, nil, :Hash), :===, s(:lvar, deconstruct_name)),
                  raise_error(:TypeError, "#deconstruct_keys must return Hash"))))
          end.then do |dnode|
            predicates.hash_deconstructed(dnode, key_names)
          end.then do |dnode|
            next dnode unless @hash_match_rest

            s(:and,
              dnode,
              hash_dup)
          end
        end

        def hash_pattern_hash_element(node, key)
          element = hash_value_at(key)
          key_index = deconstructed_key(key)
          locals.with(hash: locals[:hash, key_index]) do
            predicates.push :"k#{key_index}"
            hash_pattern_clause(node, element).tap { predicates.pop }
          end
        end

        def array_pattern_hash_element(node, key)
          element = hash_value_at(key)
          key_index = deconstructed_key(key)
          locals.with(arr: locals[:hash, key_index]) do
            predicates.push :"k#{key_index}"
            array_pattern_clause(node, element).tap { predicates.pop }
          end
        end

        def hash_element(head, *tail)
          send("#{head.type}_hash_element", head).then do |node|
            next node if tail.empty?

            right = hash_element(*tail)

            next node if right.nil?

            s(:and,
              node,
              right)
          end
        end

        def pair_hash_element(node, _key = nil)
          key, val = *node.children
          send("#{val.type}_hash_element", val, key)
        end

        def match_alt_hash_element(node, key)
          element_node = s(:lvasgn, locals[:hash, :el], hash_value_at(key))

          children = locals.with(hash_element: locals[:hash, :el]) do
            node.children.map do |child, i|
              send :"#{child.type}_hash_element", child, key
            end
          end

          s(:and,
            s(:or,
              element_node,
              s(:true)),
            s(:or, *children))
        end

        def match_as_hash_element(node, key)
          match_as_clause(node, hash_value_at(key))
        end

        def match_var_hash_element(node, key = nil)
          key ||= node.children[0]
          match_var_clause(node, hash_value_at(key))
        end

        def match_nil_pattern_hash_element(node, _key = nil)
          s(:send,
            s(:lvar, locals[:hash]),
            :empty?)
        end

        def match_rest_hash_element(node, _key = nil)
          # case {}; in **; end
          return if node.children.empty?

          child = node.children[0]

          raise ArgumentError, "Unknown hash match_rest child: #{child.type}" unless child.type == :match_var

          match_var_clause(child, s(:lvar, locals[:hash]))
        end

        def case_eq_hash_element(node, key)
          case_eq_clause node, hash_value_at(key)
        end

        def hash_value_at(key, hash = s(:lvar, locals[:hash]))
          return s(:lvar, locals.fetch(:hash_element)) if locals.key?(:hash_element)

          if @hash_match_rest
            s(:send,
              hash, :delete,
              key.to_ast_node)
          else
            s(:index,
              hash,
              key.to_ast_node)
          end
        end

        def hash_has_key(key, hash = s(:lvar, locals[:hash]))
          s(:send,
            hash, :key?,
            key.to_ast_node)
        end

        def having_hash_keys(keys, hash = s(:lvar, locals[:hash]))
          key = keys.shift
          node = predicates.hash_key(hash_has_key(key, hash), key)

          keys.reduce(node) do |res, key|
            s(:and,
              res,
              predicates.hash_key(hash_has_key(key, hash), key))
          end
        end

        #=========== HASH PATTERN (END) ===============

        def with_guard(node, guard)
          return node unless guard

          s(:and,
            node,
            guard.children[0]).then do |expr|
            next expr unless guard.type == :unless_guard
            s(:send, expr, :!)
          end
        end

        def no_matching_pattern
          raise_error(
            :NoMatchingPatternError,
            s(:send,
              s(:lvar, locals[:matchee]), :inspect)
          )
        end

        def raise_error(type, msg = "")
          s(:send, s(:const, nil, :Kernel), :raise,
            s(:const, nil, type),
            msg.to_ast_node)
        end

        # Add respond_to? check
        def respond_to_check(node, mid)
          s(:send, node, :respond_to?, mid.to_ast_node)
        end

        def respond_to_missing?(mid, *)
          return true if mid.match?(/_(clause|array_element)/)
          super
        end

        def method_missing(mid, *args, &block)
          return case_eq_clause(*args) if mid.match?(/_clause$/)
          return case_eq_array_element(*args) if mid.match?(/_array_element$/)
          return case_eq_hash_element(*args) if mid.match?(/_hash_element$/)
          super
        end

        private

        attr_reader :deconstructed_keys, :predicates

        # Raise SyntaxError if match-var is used within alternation
        # https://github.com/ruby/ruby/blob/672213ef1ca2b71312084057e27580b340438796/compile.c#L5900
        def check_match_var_alternation!(name)
          return unless locals.key?(ALTERNATION_MARKER)

          return if name.start_with?("_")

          raise ::SyntaxError, "illegal variable in alternative pattern (#{name})"
        end

        def deconstructed_key(key)
          return deconstructed_keys[key] if deconstructed_keys.key?(key)

          deconstructed_keys[key] = :"k#{deconstructed_keys.size}"
        end
      end
    end
  end
end
