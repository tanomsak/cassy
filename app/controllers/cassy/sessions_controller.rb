module Cassy
  class SessionsController < ApplicationController
    include Cassy::Utils
    include Cassy::CAS

    def new
      detect_ticketing_service(params[:service])
      
      @renew = params['renew']
      @gateway = params['gateway'] == 'true' || params['gateway'] == '1'
      @hostname = env['HTTP_X_FORWARDED_FOR'] || env['REMOTE_HOST'] || env['REMOTE_ADDR']
      tgt, tgt_error = Cassy::TicketGrantingTicket.validate(request.cookies['tgt'])
      if tgt && !tgt_error
        flash.now[:notice] = "You are currently logged in as '%s'. If this is not you, please log in below." % ticketed_user(tgt).send(settings[:username_field])
      end

      if params['redirection_loop_intercepted']
        flash.now[:error] = "The client and server are unable to negotiate authentication. Please try logging in again later."
      end
      
      if @service
        if @ticketed_user && cas_login
          redirect_to @service_with_ticket
        elsif !@renew && tgt && !tgt_error
          find_or_generate_service_tickets(ticket_username, tgt)
          st = @service_tickets[@ticketing_service]
          redirect_to = service_uri_with_ticket(@ticketing_service, st)
        elsif @gateway
          redirect_to = @gateway
        end
      elsif @gateway
        flash.now[:error] = "The server cannot fulfill this gateway request because no service parameter was given."
      end

      @lt = generate_login_ticket.ticket
    end
    
    def create
      @lt = generate_login_ticket.ticket # in case the login isn't successful, another ticket needs to be generated for the next attempt at login
      detect_ticketing_service(params[:service])
      @hostname = env['HTTP_X_FORWARDED_FOR'] || env['REMOTE_HOST'] || env['REMOTE_ADDR']
      consume_ticket = Cassy::LoginTicket.validate(@lt)
      if !consume_ticket[:valid]
        flash.now[:error] = consume_ticket[:error]
        @lt = generate_login_ticket.ticket
        render(:new, :status => 500) and return
      end

      logger.debug("Logging in with username: #{@username}, lt: #{@lt}, service: #{@service}, auth: #{settings[:auth].inspect}")
      if cas_login
        if @ticketing_service
          redirect_to @service_with_ticket, :status => 303 if @service_with_ticket# response code 303 means "See Other" (see Appendix B in CAS Protocol spec)
        else
          flash.now[:notice] = "You have successfully logged in."
          render :new
        end
      else
        incorrect_credentials!
      end
    end
    
    def destroy
      # The behaviour here is somewhat non-standard. Rather than showing just a blank
      # "logout" page, we take the user back to the login page with a "you have been logged out"
      # message, allowing for an opportunity to immediately log back in. This makes it
      # easier for the user to log out and log in as someone else.
      @service = clean_service_url(params['service'] || params['destination'])
      @continue_url = params['url']

      @gateway = params['gateway'] == 'true' || params['gateway'] == '1'

      tgt = Cassy::TicketGrantingTicket.find_by_ticket(request.cookies['tgt'])

      response.delete_cookie 'tgt'
      
      if tgt
        Cassy::TicketGrantingTicket.transaction do
          pgts = Cassy::ProxyGrantingTicket.find(:all,
            :conditions => [ActiveRecord::Base.connection.quote_table_name(Cassy::ServiceTicket.table_name)+".username = ?", tgt.username],
            :include => :service_ticket)
          pgts.each do |pgt|
            pgt.destroy
          end
          tgt.destroy
        end
      end
       
      flash[:notice] = "You have successfully logged out."
      @lt = generate_login_ticket

      if @gateway && @service
        redirect_to @service, :status => 303
      else
        redirect_to :action => :new, :service => @service
      end
    end
    
    def service_validate
      # takes a params[:service] and a params[:ticket] and validates them
      
      # required
      @service = clean_service_url(params['service'])
      @ticket = params['ticket']
      # optional
      @renew = params['renew']

      st, @error = Cassy::ServiceTicket.validate(@service, @ticket)
      @success = st && !@error
      if @success
        @username = ticketed_user(st).send(settings[:client_app_user_field])
        if @pgt_url
          pgt = generate_proxy_granting_ticket(@pgt_url, st)
          @pgtiou = pgt.iou if pgt
        end
        @extra_attributes = st.granted_by_tgt ? st.granted_by_tgt.extra_attributes : {}
      else
        status = response_status_from_error(@error) if @error
      end
      render :proxy_validate, :layout => false, :status => status || 200
    end
    
    def proxy_validate
      # required
      @service = clean_service_url(params['service'])
      @ticket = params['ticket']
      # optional
      @pgt_url = params['pgtUrl']
      @renew = params['renew']

      @proxies = []

      t, @error = Cassy::ProxyTicket.validate(@service, @ticket)
      @success = t && !@error

      @extra_attributes = {}
      if @success
        @username = ticketed_user(t)[settings[:cas_app_user_filed]]

        if t.kind_of? Cassy::ProxyTicket
          @proxies << t.granted_by_pgt.service_ticket.service
        end

        if @pgt_url
          pgt = generate_proxy_granting_ticket(@pgt_url, t)
          @pgtiou = pgt.iou if pgt
        end

        @extra_attributes = t.granted_by_tgt.extra_attributes || {}
      end

      status = response_status_from_error(@error) if @error

      render :proxy_validate, :layout => false, :status => status || 200
      
    end
    
    private
    
    def response_status_from_error(error)
      case error.code.to_s
      when /^INVALID_/, 'BAD_PGT'
        422
      when 'INTERNAL_ERROR'
        500
      else
        500
      end
    end
    
    def incorrect_credentials!
      @lt = generate_login_ticket.ticket
      flash.now[:error] = "Incorrect username or password."
      render :new, :status => 401
    end

  end
end
