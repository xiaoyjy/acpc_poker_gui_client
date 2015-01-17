require 'application_helper'
require 'acpc_poker_types/seat'
require 'match'
require 'user'
require 'hotkey'

require 'ap'

class MatchViewManagerController < ApplicationController
  include ApplicationHelper
  include PlayerActionsHelper
  helper_method(
    :match_view,
    :stale_slice?,
    :player_role_id,
    :user_must_act?,
    :next_hand_button_visible?,
    :wager_disabled?,
    :fold_disabled?,
    :pass_action_button_label,
    :make_wager_button_label
  )

  protected

  def ensure_match_view_exists
    if (
      match_id && !Match.id_exists?(match_id)
    ) || !match_view
      clear_match_information!
      return reset_to_match_entry_view
    end
  end

  def update_match_id_if_necessary
    match_id(params['match_id']) if params['match_id'] && !params['match_id'].empty?
    clear_nonexistant_match
  end

  def match_view() @match_view end

  def stale_slice?
    match_view.last_slice_viewed < (match_view.slices.length - 1)
  end

  def player_role_id(player_seat)
    if (
      !match_view.hand_ended? &&
      match_view.slice.seat_next_to_act == player_seat
    )
      PlayerActionsHelper::ACTOR_ID
    else
      PlayerActionsHelper::PLAYER_NOT_ACTING_ID
    end
  end

  def user_must_act?
    match_view.users_turn_to_act? || match_view.hand_ended?
  end
  def next_hand_button_visible?
    !match_view.match_ended? && match_view.hand_ended?
  end

  def wager_disabled?
    spectating? ||
    !(
      user_must_act? &&
      (
        match_view.legal_actions.include?(AcpcPokerTypes::PokerAction::RAISE) ||
        match_view.legal_actions.include?(AcpcPokerTypes::PokerAction::BET)
      )
    )
  end
  def fold_disabled?
    spectating? ||
    !(
      user_must_act? &&
      match_view.legal_actions.include?(AcpcPokerTypes::PokerAction::FOLD)
    )
  end
  def pass_action_button_label
    if (
      match_view.legal_actions.include?(AcpcPokerTypes::PokerAction::CALL) &&
      match_view.amount_for_next_player_to_call > 0
    )
      if match_view.no_limit?
        "#{PlayerActionsHelper::CALL_LABEL} (#{match_view.amount_for_next_player_to_call.to_i})"
      else
       PlayerActionsHelper::CALL_LABEL
      end
    else
      PlayerActionsHelper::CHECK_LABEL
    end
  end
  def make_wager_button_label
    label = if match_view.legal_actions.include?('b')
      PlayerActionsHelper::BET_LABEL
    else
      PlayerActionsHelper::RAISE_LABEL
    end
    label += ' to' if match_view.no_limit?
    label
  end
  def update_match_view!
    begin
      Rails.logger.ap(
        {
          method: __method__,
          match_slice: match_view.slice_index,
          messages_to_display: match_view.messages_to_display,
          message: "Before #next_slice!"
        }
      )
      match_view.next_slice!
      Rails.logger.ap(
        {
          method: __method__,
          match_slice: match_view.slice_index,
          messages_to_display: match_view.messages_to_display,
          message: "After #next_slice!"
        }
      )
    rescue MatchView::UnableToFindNextSlice => e
      Rails.logger.ap method: __method__, match_slice: match_view.slice_index, message: e.message
      raise e
    else
      unless spectating?
        match.last_slice_viewed = match_view.slice_index
        match.save!
      end
    end
  end
end

# Controller for the main game view where the table and actions are presented to the player.
# Implements the actions in the main match view.
class PlayerActionsController < MatchViewManagerController
  before_filter :abort_if_too_many_requests

  def abort_if_too_many_requests
    if session['num_requests'] && session['num_requests'].to_i > 100
      Rails.logger.ap method: __method__, too_many_repeat_requests: session['num_requests']
      session['num_requests'] = 0
      clear_match_information!
      return redirect_to root_path
    end
  end

  def index
    session['num_requests'] ||= 0
    session['num_requests'] += 1
    return reset_to_match_entry_view(
      "Sorry, there was a problem retrieving match #{match_id}, #{self.class.report_error_request_message}."
    ) if (
      error? do
        update_match_id_if_necessary
        @match_view = MatchView.new match_id, params['match_slice_index'], params['load_previous_messages']

        last_slice_viewed = @match_view.given_slice_index - 1

        Rails.logger.ap action: __method__, hand_ended: @match_view.hand_ended?, last_slice_viewed: last_slice_viewed

        return (
          if @match_view.match_ended?
            render nothing: true
          elsif @match_view.hand_ended?
            if last_slice_viewed == @match_view.slice_index && !@match_view.loaded_previous_messages?
              @match_view.messages_to_display = []
            end
            if spectating? && @match_view.last_slice_viewed > @match_view.slice_index
              update_match
            else
              replace_page_contents_with_updated_game_view
            end
          else
            update_match
          end
        )
      end
    )
  end

  def update_match
    session['num_requests'] ||= 0
    session['num_requests'] += 1
    return reset_to_match_entry_view(
      "Sorry, there was a problem continuing match #{match_id}, #{self.class.report_error_request_message}."
    ) if (
      error? do
        update_match_id_if_necessary
        @match_view ||= MatchView.new match_id, params['match_slice_index']

        last_slice_viewed = @match_view.given_slice_index - 1

        Rails.logger.ap(
          action: __method__,
          last_slice_viewed: last_slice_viewed,
          slice_index: @match_view.slice_index,
          num_slices: @match_view.slices.length
        )

        last_slice_viewed = @match_view.given_slice_index || @match_view.last_slice_viewed

        if @match_view.slice_index < (@match_view.slices.length - 1) && @match_view.slice_index <= last_slice_viewed
          update_match_view!
        elsif @match_view.slice_index > @match_view.last_slice_viewed && !spectating?
          match.last_slice_viewed = match_view.slice_index
          match.save!
        end

        if last_slice_viewed == @match_view.slice_index && !@match_view.loaded_previous_messages?
          @match_view.messages_to_display = []
        end

        if @match_view.slice_index > last_slice_viewed
          session['num_requests'] = 0
        end

        Rails.logger.ap(
          action: __method__,
          match_slice_index_to_be_rendered: @match_view.slice_index,
          view_ms: @match_view.state.to_s
        )

        return replace_page_contents_with_updated_game_view
      end
    )
  end

  def play_action
    return reset_to_match_entry_view(
      "Sorry, there was a problem taking action #{params[:poker_action]}, #{self.class.report_error_request_message}."
    ) if (
      error? do
        update_match_id_if_necessary
        TableManager::Worker.perform_async(
          TableManager::PLAY_ACTION_REQUEST_CODE,
          {
            TableManager::MATCH_ID_KEY => match_id,
            TableManager::ACTION_KEY => params[:poker_action]
          }
        )
      end
    )
    render nothing: true
  end

  def update_hotkeys
    return reset_to_match_entry_view(
      "Sorry, there was a problem saving hotkeys, #{self.class.report_error_request_message}."
    ) if (
      error? do
        Rails.logger.ap(
          action: __method__,
          params: params
        )

        hotkey_hash = params[PlayerActionsHelper::CUSTOMIZE_HOTKEYS_ID]

        # @todo Update this in master
        if params[PlayerActionsHelper::CUSTOMIZE_HOTKEYS_AMOUNT_KEY]
          params[PlayerActionsHelper::CUSTOMIZE_HOTKEYS_AMOUNT_KEY].zip(
            params[PlayerActionsHelper::CUSTOMIZE_HOTKEYS_KEYS_HASH_KEY]
          ).each do |amount, key|
            hotkey_hash[Hotkey.wager_hotkey_label(amount.to_f)] = key
          end
        end

        begin
          user.update_hotkeys! hotkey_hash
        rescue User::ConflictingHotkeys => e
          @alert_message = "Sorry, the following hotkeys conflicted and were not saved: \n" << e.message << "\n"

          Rails.logger.ap(
            action: __method__,
            alert_message: @alert_message
          )
        end

        return replace_page_contents_with_updated_game_view
      end
    )
    reset_to_match_entry_view
  end

  def reset_hotkeys
    Rails.logger.ap(action: __method__)

    user.reset_hotkeys!
    return replace_page_contents_with_updated_game_view
  end

  def leave_match
    Rails.logger.ap(
      action: __method__,
      was_spectating: spectating?,
      user: user.name,
      match_id: match_id,
      match_user_name: match.user_name
    )
    unless spectating? || match_id.nil?
      Match.delete_match! match_id
      Rails.logger.ap(action: __method__, message: "Deleted match #{match_id}")

      TableManager::Worker.perform_async(
        TableManager::KILL_MATCH,
        {TableManager::MATCH_ID_KEY => match_id}
      )
    end
    @alert_message = params['alert_message'] if params['alert_message'] && !params['alert_message'].empty?
    Rails.logger.ap(
      action: __method__,
      alert_message: @alert_message
    )
    clear_match_information!
    reset_to_match_entry_view
  end

  protected

  def my_helper() PlayerActionsHelper end

  # Replaces the page contents with an updated game view
  def replace_page_contents_with_updated_game_view
    @match_view ||= MatchView.new(match_id)
    ensure_match_view_exists

    replace_page_contents(
      replacement_partial: 'player_actions/index',
      html_element: html_element_name_to_class(
        ApplicationHelper::POKER_VIEW_HTML_CLASS
      )
    )
  end
end
