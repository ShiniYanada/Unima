class Api::V1::ProductsController < ApplicationController
    before_action :authenticate_api_user!, except: [:index, :show, :search]
    before_action :set_product, except: [:index, :search, :create]
    before_action :correct_user, only: [:update, :destroy]

    def index 
        @products = Product.where(status: 'open')

        render json: @products
    end

    def show
        if @product
            @comments = @product.comments
            like = current_api_user&.liking?(@product)

            render json: {
                like: like,
                product: @product.as_json(include: {
                    seller: { only: [:name, :avatar]},
                    category: { methods: :path }
                }),
                comments: @comments.as_json(include: { user: {only: [:name, :id, :avatar]}})
            }
        else
            head :not_found 
        end
    end

    def search
        @q = Product.ransack(params[:q])
        @pagy, @products = pagy(@q.result)
        render json: { products: @products, pagy: pagy_metadata(@pagy)}
    end

    def create 
        head :forbidden and return if current_api_user.stripe_account_id.nil?

        begin
            account = Stripe::Account.retrieve(current_api_user.stripe_account_id)
        rescue => e
            head :bad_request and return
        end

        @category = Category.find_by(name: category_params[:category])
        @product = current_api_user.sell_products.build(product_params)
        @product.category_id = @category.id if @category

        if @product.save 
            render json: @product, status: :created
        else
            render json: @product.errors, status: :unprocessable_entity
        end
    end

    def update
        head :forbidden and return if @product.status == "trade" || @product.status == "close"

        add_more_images(product_images_params[:images]) unless params[:images].nil?
        
        remove_image_at_index(params[:remove_ids]) unless params[:remove_ids].nil?

        if @product.update(product_params_except_images)
            render json: @product
        else
            render json: @product.errors, status: :unprocessable_entity
        end
        
    end

    def destroy
        if @product.destroy
            render json: @product
        else
            head :unprocessable_entity	
        end
    end
    
    #商品の取引を開始
    def trade
        begin
            token = Stripe::Customer.retrieve(current_api_user.stripe_customer_id)
        rescue => e
            head :bad_request and return
        end

        seller = @product.seller

        if current_api_user == @seller || !(@product.status == "open")
            head :forbidden and return
        end

        if @product.update_attributes(buyer_id: current_api_user.id, status: "trade", traded_at: Time.zone.now)
            UserMailer.with(buyer: current_api_user, seller: seller, product: @product).purchase.deliver_later
            UserMailer.with(buyer: current_api_user, seller: seller, product: @product).sold.deliver_later
            render json: @product
        else
            render json: @product.errors, status: :unprocessable_entity
        end
    end

    #取引をキャンセル
    def cancel
        seller = @product.seller
        buyer = @product.buyer
        unless current_api_user == seller && @product.status == "trade"
            head :forbidden and return
        end

        if @product.update_attributes(buyer_id: nil, status: "open", traded_at: nil)
            UserMailer.with(buyer: buyer, seller: seller, product: @product).purchase.deliver_later
            UserMailer.with(buyer: buyer, seller: seller, product: @product).sold.deliver_later
            head :ok
        else
            head :unprocessable_entity
        end
    end

    #取引を完了
    def complete
        seller = @product.seller

        begin
            account_token = Stripe::Account.retrieve(seller.stripe_account_id)
            customer_token = Stripe::Customer.retrieve(current_api_user.stripe_account_id)
        rescue => e
            head :bad_request
        end
        
        unless current_api_user == @product.buyer && @product.status == "trade"
            head :forbidden
        end

        begin
            Stripe::Charge.create({
                amount: @product.price,
                currency: "jpy",
                customer: current_api_user.stripe_customer_id,
                transfer_data: {
                    amount: (@product.price * 0.9).to_i,
                    destination: seller.stripe_account_id,
                }
            })
            if @product.update_attributes(status: "close", closed_at: Time.zone.now)
                head :ok
            else
                render json: @product.errors, status: :unprocessable_entity
            end
        rescue => e
            head :bad_request
        end
    end

    #取引中の商品を返す
    def trading
        head :forbidden unless current_api_user == @product.buyer || current_api_user == @product.seller

        if @product
            @messages = @product.trade_messages
            like = current_api_user&.liking?(@product)

            render json: {
                like: like,
                product: @product.as_json(include: {
                    seller: { only: [:name, :avatar]},
                    category: { methods: :path }
                }),
                messages: @messages.as_json(include: { user: {only: [:name, :id, :avatar]}})
            }
        else
            head :not_found 
        end
    end

    #購入手続き画面の情報を出力
    def confirmation
        if @product
            customer_id = current_api_user.stripe_customer_id

            if customer_id.nil?
                render json: { product: @product }
            else
                begin
                    customer = Stripe::Customer.retrieve(customer_id)
                    data = customer[:sources][:data][0]
                    last4 = data[:last4]
                    exp_month = data[:exp_month]
                    exp_year = data[:exp_year]
                    brand = data[:brand]
                    cregit = {last4: last4, exp_month: exp_month, exp_year: exp_year, brand: brand}
                    render json: { product: @product, card: cregit }
                rescue => e
                    head :bad_request
                end
            end
        else
            head :not_found
        end
    end

    private 

        def product_params 
            params.permit(:name, :description, :price, :state, { images: [] })
        end

        def product_params_except_images
            params.permit(:name, :description, :price, :state)
        end

        def product_images_params
            params.permit({ images: []})
        end

        def category_params
            params.permit(:category)
        end

        def set_product
            @product = Product.find_by(id: params[:id])
        end

        #売り手かどうか
        def correct_user 
            head :forbidden if current_api_user == !@product.seller
        end

        def add_more_images(new_images)
            images = @product.images 
            images += new_images
            @product.images = images
        end

        def remove_image_at_index(ids)
            ids.each do |id|
                index = id.to_i
                remain_images = @product.images
                if index == 0 && @product.images.size == 1
                    @product.remove_images!
                else
                    deleted_image = remain_images.delete_at(index) 
                    deleted_image.try(:remove!)
                    @product.images = remain_images
                end
            end
        end
end
